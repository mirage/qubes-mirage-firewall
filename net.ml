(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** General network stuff (needs reorganising). *)

open Lwt.Infix
open Utils

module Eth = Ethif.Make(Netif)

module Netback = Netchannel.Backend.Make(Netchannel.Xenstore.Make(OS.Xs))
module ClientEth = Ethif.Make(Netback)

let src = Logs.Src.create "net" ~doc:"Firewall networking"
module Log = (val Logs.src_log src : Logs.LOG)

(* The checksum logic doesn't depend on ARP or Eth, but we can't access
   IPv4.checksum without applying the functor. *)
let fixup_checksums frame =
  match Nat_rewrite.layers frame with
  | None -> raise (Invalid_argument "NAT transformation rendered packet unparseable")
  | Some (ether, ip, tx) ->
    let (just_headers, higherlevel_data) =
      Nat_rewrite.recalculate_transport_checksum (ether, ip, tx)
    in
    [just_headers; higherlevel_data]

module Make(Clock : V1.CLOCK) = struct
  module Arp = Arpv4.Make(Eth)(Clock)(OS.Time)
  module IPv4 = Ipv4.Make(Eth)(Arp)
  module Xs = OS.Xs

  let eth_header ~src ~dst =
    let open Wire_structs in
    let frame = Cstruct.create sizeof_ethernet in
    frame |> set_ethernet_src (Macaddr.to_bytes src) 0;
    frame |> set_ethernet_dst (Macaddr.to_bytes dst) 0;
    set_ethernet_ethertype frame (ethertype_to_int IPv4);
    frame

  class netvm_iface eth my_ip mac nat_table : interface = object
    method my_mac = Eth.mac eth
    method writev ip =
      mac >>= fun dst ->
      let eth_hdr = eth_header ~src:(Eth.mac eth) ~dst in
      match Nat_rules.nat my_ip nat_table Nat_rewrite.Source (Cstruct.concat (eth_hdr :: ip)) with
      | None -> return ()
      | Some frame -> Eth.writev eth (fixup_checksums frame)
  end

  class client_iface eth client_ip client_mac : client_link = object
    method my_mac = ClientEth.mac eth
    method client_mac = client_mac
    method client_ip = client_ip
    method writev ip =
      let eth_hdr = eth_header ~src:(ClientEth.mac eth) ~dst:client_mac in
      ClientEth.writev eth (fixup_checksums (Cstruct.concat (eth_hdr :: ip)))
  end

  let or_fail msg = function
    | `Ok x -> return x
    | `Error _ -> fail (Failure msg)

  let clients : Cleanup.t IntMap.t ref = ref IntMap.empty

  let forward_ipv4 router buf =
    match Memory_pressure.status () with
    | `Memory_critical -> (* TODO: should happen before copying and async *)
        print_endline "Memory low - dropping packet";
        return ()
    | `Ok ->
    match Router.target router buf with
    | Some iface -> iface#writev [buf]
    | None -> return ()

  let start_client ~router domid =
    let cleanup_tasks = Cleanup.create () in
    Log.info "start_client in domain %d" (fun f -> f domid);
    Lwt.async (fun () ->
      Lwt.catch (fun () ->
        Dao.client_vifs domid >>= (function
        | [] -> return None
        | vif :: others ->
            if others <> [] then Log.warn "Client has multiple interfaces; using first" Logs.unit;
            let { Dao.domid; device_id; client_ip } = vif in
            Netback.make ~domid ~device_id >|= fun backend ->
            Some (backend, client_ip)
        ) >>= function
        | None -> Log.warn "Client has no interfaces" Logs.unit; return ()
        | Some (backend, client_ip) ->
        Log.info "Client %d (IP: %s) ready" (fun f ->
          f domid (Ipaddr.V4.to_string client_ip));
        ClientEth.connect backend >>= or_fail "Can't make Ethernet device" >>= fun eth ->
        let client_mac = Netback.mac backend in
        let iface = new client_iface eth client_ip client_mac in
        let fixed_arp = Client_net.ARP.create ~net:(Router.client_net router) iface in
        Router.add_client router iface;
        Cleanup.on_cleanup cleanup_tasks (fun () -> Router.remove_client router iface);
        Netback.listen backend (
          ClientEth.input
            ~arpv4:(fun buf ->
              match Client_net.ARP.input fixed_arp buf with
              | None -> return ()
              | Some frame -> ClientEth.write eth frame
            )
            ~ipv4:(fun packet ->
              let src = Wire_structs.Ipv4_wire.get_ipv4_src packet |> Ipaddr.V4.of_int32 in
              if src === client_ip then forward_ipv4 router packet
              else (
                Log.warn "Incorrect source IP %a in IP packet from %a (dropping)"
                  (fun f -> f Ipaddr.V4.pp_hum src Ipaddr.V4.pp_hum client_ip);
                return ()
              )
            )
            ~ipv6:(fun _buf -> return ())
            eth
        )
      )
      (fun ex ->
        Log.warn "Error connecting client domain %d: %s"
          (fun f -> f domid (Printexc.to_string ex));
        return ()
      )
    );
    cleanup_tasks

  let watch_clients router =
    let backend_vifs = "backend/vif" in
    Log.info "Watching %s" (fun f -> f backend_vifs);
    Dao.watch_clients (fun new_set ->
      (* Check for removed clients *)
      !clients |> IntMap.iter (fun key cleanup ->
        if not (IntSet.mem key new_set) then (
          clients := !clients |> IntMap.remove key;
          Log.info "stop_client %d" (fun f -> f key);
          Cleanup.cleanup cleanup
        )
      );
      (* Check for added clients *)
      new_set |> IntSet.iter (fun key ->
        if not (IntMap.mem key !clients) then (
          let cleanup = start_client ~router key in
          clients := !clients |> IntMap.add key cleanup
        )
      )
    )

  let connect_uplink config =
    let nat_table = Nat_lookup.empty () in
    let ip = config.Dao.uplink_our_ip in
    Netif.connect "tap0" >>= function
    | `Error (`Unknown msg) -> failwith msg
    | `Error `Disconnected -> failwith "Disconnected"
    | `Error `Unimplemented -> failwith "Unimplemented"
    | `Ok net0 ->
    Eth.connect net0 >>= or_fail "Can't make Ethernet device for tap" >>= fun eth0 ->
    Arp.connect eth0 >>= or_fail "Can't add ARP" >>= fun arp0 ->
    Arp.add_ip arp0 ip >>= fun () ->
    let netvm_mac = Arp.query arp0 config.Dao.uplink_netvm_ip >|= function
      | `Timeout -> failwith "ARP timeout getting MAC of our NetVM"
      | `Ok netvm_mac -> netvm_mac in
    let ip46 = Ipaddr.V4 ip in
    let iface = new netvm_iface eth0 ip46 netvm_mac nat_table in
    let listen router =
      let unnat frame _ip = 
        match Nat_rules.nat ip46 nat_table Nat_rewrite.Destination frame with
        | None ->
            Log.debug "Discarding unexpected frame" Logs.unit;
            return ()
        | Some frame ->
            let frame = fixup_checksums frame |> Cstruct.concat in
            forward_ipv4 router (Cstruct.shift frame Wire_structs.sizeof_ethernet) in
      Netif.listen net0 (fun frame ->
        Eth.input
          ~arpv4:(Arp.input arp0)
          ~ipv4:(unnat frame)
          ~ipv6:(fun _buf -> return ())
          eth0 frame
      ) in
    return (iface, listen)

  let connect qubesDB =
    let config = Dao.read_network_config qubesDB in
    connect_uplink config >>= fun (netvm_iface, netvm_listen) ->
    Dao.set_iptables_error qubesDB "" >>= fun () ->
    Logs.info "Client (internal) network is %a"
      (fun f -> f Ipaddr.V4.Prefix.pp_hum config.Dao.clients_prefix);
    let client_net = Client_net.create
      ~client_gw:config.Dao.clients_our_ip
      ~prefix:config.Dao.clients_prefix in
    let router = Router.create
      ~default_gateway:netvm_iface
      ~client_net in
    Lwt.join [
      watch_clients router;
      netvm_listen router
    ]
end
