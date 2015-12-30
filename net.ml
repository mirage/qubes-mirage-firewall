(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** General network stuff (needs reorganising). *)

open Lwt.Infix
open Utils
open Qubes

module StringMap = Map.Make(String)
module StringSet = Set.Make(String)

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

  let random_user_port () =
    1024 + Random.int (0xffff - 1024)

  let pp_ip4 = Ipaddr.V4.pp_hum

  let or_fail msg = function
    | `Ok x -> return x
    | `Error _ -> fail (Failure msg)

  let clients : Cleanup.t StringMap.t ref = ref StringMap.empty

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
    Log.info "start_client in domain %s" (fun f -> f domid);
    Lwt.async (fun () ->
      Lwt.catch (fun () ->
        let domid = int_of_string domid in
        let path = Printf.sprintf "backend/vif/%d" domid in
        OS.Xs.make () >>= fun xs ->
        OS.Xs.immediate xs (fun h ->
          OS.Xs.directory h path >>= function
          | [] -> return None
          | device_id :: others ->
              if others <> [] then Log.warn "Client has multiple interfaces; using first" Logs.unit;
              let device_id = int_of_string device_id in
              OS.Xs.read h (Printf.sprintf "%s/%d/ip" path device_id) >>= fun client_ip ->
              Netback.make ~domid ~device_id >|= fun backend ->
              Some (backend, Ipaddr.V4.of_string_exn client_ip)
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
        Log.warn "Error connecting client domain %s: %s"
          (fun f -> f domid (Printexc.to_string ex));
        return ()
      )
    );
    cleanup_tasks

  let watch_clients ~router xs =
    let backend_vifs = "backend/vif" in
    Log.info "Watching %s" (fun f -> f backend_vifs);
    Xs.wait xs (fun handle ->
      begin Lwt.catch
        (fun () -> Xs.directory handle backend_vifs)
        (function
          | Xs_protocol.Enoent _ -> return []
          | ex -> fail ex)
      end >>= fun items ->
      Log.debug "Items: %s" (fun f -> f (String.concat ", " items));
      let new_set = items
        |> List.fold_left (fun acc key -> StringSet.add key acc) StringSet.empty in
      (* Check for removed clients *)
      !clients |> StringMap.iter (fun key cleanup ->
        if not (StringSet.mem key new_set) then (
          clients := !clients |> StringMap.remove key;
          Log.info "stop_client %S" (fun f -> f key);
          Cleanup.cleanup cleanup
        )
      );
      (* Check for added clients *)
      new_set |> StringSet.iter (fun key ->
        if not (StringMap.mem key !clients) then (
          let cleanup = start_client ~router key in
          clients := !clients |> StringMap.add key cleanup
        )
      );
      (* Wait for further updates *)
      fail Xs_protocol.Eagain
    )

  let connect qubesDB ~xs =
    let nat_table = Nat_lookup.empty () in
    let get name =
      match DB.read qubesDB name with
      | None -> raise (error "QubesDB key %S not present" name)
      | Some value -> value in
    let ip = get "/qubes-ip" |> Ipaddr.of_string_exn in
    (* let netmask = get "/qubes-netmask" |> Ipaddr.V4.of_string_exn in *)
    let gateway = get "/qubes-gateway" |> Ipaddr.V4.of_string_exn in
    (* This is oddly named: seems to be the network we provde to our clients *)
    let client_prefix =
      let client_network = get "/qubes-netvm-network" |> Ipaddr.V4.of_string_exn in
      let client_netmask = get "/qubes-netvm-netmask" |> Ipaddr.V4.of_string_exn in
      Ipaddr.V4.Prefix.of_netmask client_netmask client_network in
    let client_gw = get "/qubes-netvm-gateway" |> Ipaddr.V4.of_string_exn in
    Netif.connect "tap0" >>= function
    | `Error (`Unknown msg) -> failwith msg
    | `Error `Disconnected -> failwith "Disconnected"
    | `Error `Unimplemented -> failwith "Unimplemented"
    | `Ok net0 ->
    Eth.connect net0 >>= or_fail "Can't make Ethernet device for tap" >>= fun eth0 ->
    Arp.connect eth0 >>= or_fail "Can't add ARP" >>= fun arp0 ->
    match Ipaddr.to_v4 ip with
    | None -> failwith "Don't have an IPv4 address!"
    | Some ip4 ->
    Arp.add_ip arp0 ip4 >>= fun () ->
    DB.write qubesDB "/qubes-iptables-error" "" >>= fun () ->
    Logs.info "Client (internal) network is %a"
      (fun f -> f Ipaddr.V4.Prefix.pp_hum client_prefix);
    let netvm_iface =
      let netvm_mac = Arp.query arp0 gateway >|= function
        | `Timeout -> failwith "ARP timeout getting MAC of our NetVM"
        | `Ok netvm_mac -> netvm_mac in
      new netvm_iface eth0 ip netvm_mac nat_table in
    let client_net = Client_net.create ~client_gw ~prefix:client_prefix in
    let router = Router.create ~default_gateway:netvm_iface ~client_net in
    let clients = watch_clients ~router xs in
    let wan =
      let unnat frame _ip = 
        match Nat_rules.nat ip nat_table Nat_rewrite.Destination frame with
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
    Lwt.join [clients; wan]
end
