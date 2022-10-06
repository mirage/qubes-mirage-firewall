(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix
open Fw_utils

module Netback = Netchannel.Backend.Make(Netchannel.Xenstore.Make(Xen_os.Xs))
module ClientEth = Ethernet.Make(Netback)

let src = Logs.Src.create "client_net" ~doc:"Client networking"
module Log = (val Logs.src_log src : Logs.LOG)

let writev eth dst proto fillfn =
  Lwt.catch
    (fun () ->
       ClientEth.write eth dst proto fillfn >|= function
       | Ok () -> ()
       | Error e ->
         Log.err (fun f -> f "error trying to send to client: @[%a@]"
                     ClientEth.pp_error e);
    )
    (fun ex ->
       (* Usually Netback_shutdown, because the client disconnected *)
       Log.err (fun f -> f "uncaught exception trying to send to client: @[%s@]"
                   (Printexc.to_string ex));
       Lwt.return_unit
    )

class client_iface eth ~domid ~gateway_ip ~client_ip client_mac : client_link =
  let log_header = Fmt.str "dom%d:%a" domid Ipaddr.V4.pp client_ip in
  object
    val mutable rules = []
    method get_rules = rules
    method set_rules new_db = rules <- Dao.read_rules new_db client_ip
    method my_mac = ClientEth.mac eth
    method other_mac = client_mac
    method my_ip = gateway_ip
    method other_ip = client_ip
    method writev proto fillfn =
        writev eth client_mac proto fillfn
    method log_header = log_header
  end

let clients : Cleanup.t Dao.VifMap.t ref = ref Dao.VifMap.empty

(** Handle an ARP message from the client. *)
let input_arp ~fixed_arp ~iface request =
  match Arp_packet.decode request with
  | Error e ->
    Log.warn (fun f -> f "Ignored unknown ARP message: %a" Arp_packet.pp_error e);
    Lwt.return_unit
  | Ok arp ->
    match Client_eth.ARP.input fixed_arp arp with
    | None -> Lwt.return_unit
    | Some response ->
      iface#writev `ARP (fun b -> Arp_packet.encode_into response b; Arp_packet.size)

(** Handle an IPv4 packet from the client. *)
let input_ipv4 get_ts cache ~iface ~router dns_client dns_servers packet =
  let cache', r = Nat_packet.of_ipv4_packet !cache ~now:(get_ts ()) packet in
  cache := cache';
  match r with
  | Error e ->
    Log.warn (fun f -> f "Ignored unknown IPv4 message: %a" Nat_packet.pp_error e);
    Lwt.return_unit
  | Ok None -> Lwt.return_unit
  | Ok (Some packet) ->
    let `IPv4 (ip, _) = packet in
    let src = ip.Ipv4_packet.src in
    if src = iface#other_ip then Firewall.ipv4_from_client dns_client dns_servers router ~src:iface packet
    else (
      Log.warn (fun f -> f "Incorrect source IP %a in IP packet from %a (dropping)"
                   Ipaddr.V4.pp src Ipaddr.V4.pp iface#other_ip);
      Lwt.return_unit
    )

(** Connect to a new client's interface and listen for incoming frames and firewall rule changes. *)
let add_vif get_ts { Dao.ClientVif.domid; device_id } dns_client dns_servers ~client_ip ~router ~cleanup_tasks qubesDB =
  Netback.make ~domid ~device_id >>= fun backend ->
  Log.info (fun f -> f "Client %d (IP: %s) ready" domid (Ipaddr.V4.to_string client_ip));
  ClientEth.connect backend >>= fun eth ->
  let client_mac = Netback.frontend_mac backend in
  let client_eth = router.Router.client_eth in
  let gateway_ip = Client_eth.client_gw client_eth in
  let iface = new client_iface eth ~domid ~gateway_ip ~client_ip client_mac in
  (* update the rules whenever QubesDB notices a change for this IP *)
  let qubesdb_updater =
    Lwt.catch
      (fun () ->
        let rec update current_db current_rules =
          Qubes.DB.got_new_commit qubesDB (Dao.db_root client_ip) current_db >>= fun new_db ->
          iface#set_rules new_db;
          let new_rules = iface#get_rules in
          (if current_rules = new_rules then
            Log.debug (fun m -> m "Rules did not change for %s" (Ipaddr.V4.to_string client_ip))
          else begin
            Log.debug (fun m -> m "New firewall rules for %s@.%a"
                        (Ipaddr.V4.to_string client_ip)
                        Fmt.(list ~sep:(any "@.") Pf_qubes.Parse_qubes.pp_rule) new_rules);
            (* empty NAT table if rules are updated: they might deny old connections *)
            My_nat.remove_connections router.Router.nat router.Router.ports client_ip;
          end);
          update new_db new_rules
        in
        update Qubes.DB.KeyMap.empty [])
      (function Lwt.Canceled -> Lwt.return_unit | e -> Lwt.fail e)
  in
  Cleanup.on_cleanup cleanup_tasks (fun () -> Lwt.cancel qubesdb_updater);
  Router.add_client router iface >>= fun () ->
  Cleanup.on_cleanup cleanup_tasks (fun () -> Router.remove_client router iface);
  let fixed_arp = Client_eth.ARP.create ~net:client_eth iface in
  let fragment_cache = ref (Fragments.Cache.empty (256 * 1024)) in
  let listener =
    Lwt.catch
      (fun () ->
        Netback.listen backend ~header_size:Ethernet.Packet.sizeof_ethernet (fun frame ->
          match Ethernet.Packet.of_cstruct frame with
          | Error err -> Log.warn (fun f -> f "Invalid Ethernet frame: %s" err); Lwt.return_unit
          | Ok (eth, payload) ->
              match eth.Ethernet.Packet.ethertype with
              | `ARP -> input_arp ~fixed_arp ~iface payload
              | `IPv4 -> input_ipv4 get_ts fragment_cache ~iface ~router dns_client dns_servers payload
              | `IPv6 -> Lwt.return_unit (* TODO: oh no! *)
        )
        >|= or_raise "Listen on client interface" Netback.pp_error)
      (function Lwt.Canceled -> Lwt.return_unit | e -> Lwt.fail e)
  in
  Cleanup.on_cleanup cleanup_tasks (fun () -> Lwt.cancel listener);
  Lwt.pick [ qubesdb_updater ; listener ]

(** A new client VM has been found in XenStore. Find its interface and connect to it. *)
let add_client get_ts dns_client dns_servers ~router vif client_ip qubesDB =
  let cleanup_tasks = Cleanup.create () in
  Log.info (fun f -> f "add client vif %a with IP %a"
               Dao.ClientVif.pp vif Ipaddr.V4.pp client_ip);
  Lwt.async (fun () ->
      Lwt.catch (fun () ->
          add_vif get_ts vif dns_client dns_servers ~client_ip ~router ~cleanup_tasks qubesDB
        )
        (fun ex ->
           Log.warn (fun f -> f "Error with client %a: %s"
                        Dao.ClientVif.pp vif (Printexc.to_string ex));
           Lwt.return_unit
        )
    );
  cleanup_tasks

(** Watch XenStore for notifications of new clients. *)
let listen get_ts dns_client dns_servers qubesDB router =
  Dao.watch_clients (fun new_set ->
    (* Check for removed clients *)
    !clients |> Dao.VifMap.iter (fun key cleanup ->
      if not (Dao.VifMap.mem key new_set) then (
        clients := !clients |> Dao.VifMap.remove key;
        Log.info (fun f -> f "client %a has gone" Dao.ClientVif.pp key);
        Cleanup.cleanup cleanup
      )
    );
    (* Check for added clients *)
    new_set |> Dao.VifMap.iter (fun key ip_addr ->
      if not (Dao.VifMap.mem key !clients) then (
        let cleanup = add_client get_ts dns_client dns_servers ~router key ip_addr qubesDB in
        Log.debug (fun f -> f "client %a arrived" Dao.ClientVif.pp key);
        clients := !clients |> Dao.VifMap.add key cleanup
      )
    )
  )
