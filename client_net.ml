(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix
open Fw_utils

module Netback = Netchannel.Backend.Make(Netchannel.Xenstore.Make(OS.Xs))
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
       Lwt.return ()
    )

class client_iface eth ~domid ~gateway_ip ~client_ip client_mac rules : client_link =
  let log_header = Fmt.strf "dom%d:%a" domid Ipaddr.V4.pp client_ip in
  object
    val queue = FrameQ.create (Ipaddr.V4.to_string client_ip)
    val rules = rules
    method get_rules = rules
    method my_mac = ClientEth.mac eth
    method other_mac = client_mac
    method my_ip = gateway_ip
    method other_ip = client_ip
    method writev proto fillfn =
      FrameQ.send queue (fun () ->
          writev eth client_mac proto fillfn
        )
    method log_header = log_header
  end

let clients : Cleanup.t Dao.VifMap.t ref = ref Dao.VifMap.empty

(** Handle an ARP message from the client. *)
let input_arp ~fixed_arp ~iface request =
  match Arp_packet.decode request with
  | Error e ->
    Log.warn (fun f -> f "Ignored unknown ARP message: %a" Arp_packet.pp_error e);
    Lwt.return ()
  | Ok arp ->
    match Client_eth.ARP.input fixed_arp arp with
    | None -> return ()
    | Some response ->
      iface#writev `ARP (fun b -> Arp_packet.encode_into response b; Arp_packet.size)

(** Handle an IPv4 packet from the client. *)
let input_ipv4 ~iface ~router packet =
  match Nat_packet.of_ipv4_packet packet with
  | Error e ->
    Log.warn (fun f -> f "Ignored unknown IPv4 message: %a" Nat_packet.pp_error e);
    Lwt.return ()
  | Ok packet ->
    let `IPv4 (ip, _) = packet in
    let src = ip.Ipv4_packet.src in
    if src = iface#other_ip then Firewall.ipv4_from_client router ~src:iface packet
    else (
      Log.warn (fun f -> f "Incorrect source IP %a in IP packet from %a (dropping)"
                   Ipaddr.V4.pp src Ipaddr.V4.pp iface#other_ip);
      return ()
    )

(** Connect to a new client's interface and listen for incoming frames. *)
let add_vif { Dao.ClientVif.domid; device_id } ~client_ip ~router ~cleanup_tasks rules =
  Netback.make ~domid ~device_id >>= fun backend ->
  Log.info (fun f -> f "Client %d (IP: %s) ready" domid (Ipaddr.V4.to_string client_ip));
  ClientEth.connect backend >>= fun eth ->
  let client_mac = Netback.frontend_mac backend in
  let client_eth = router.Router.client_eth in
  let gateway_ip = Client_eth.client_gw client_eth in
  let iface = new client_iface eth ~domid ~gateway_ip ~client_ip client_mac rules in
  Router.add_client router iface >>= fun () ->
  Cleanup.on_cleanup cleanup_tasks (fun () -> Router.remove_client router iface);
  let fixed_arp = Client_eth.ARP.create ~net:client_eth iface in
  Netback.listen backend ~header_size:Ethernet_wire.sizeof_ethernet (fun frame ->
    match Ethernet_packet.Unmarshal.of_cstruct frame with
    | exception ex ->
      Log.err (fun f -> f "Error unmarshalling ethernet frame from client: %s@.%a" (Printexc.to_string ex)
                  Cstruct.hexdump_pp frame
              );
      Lwt.return_unit
    | Error err -> Log.warn (fun f -> f "Invalid Ethernet frame: %s" err); return ()
    | Ok (eth, payload) ->
        match eth.Ethernet_packet.ethertype with
        | `ARP -> input_arp ~fixed_arp ~iface payload
        | `IPv4 -> input_ipv4 ~iface ~router payload
        | `IPv6 -> return () (* TODO: oh no! *)
  )
  >|= or_raise "Listen on client interface" Netback.pp_error

(** A new client VM has been found in XenStore. Find its interface and connect to it. *)
let add_client ~router vif client_ip rules =
  let cleanup_tasks = Cleanup.create () in
  Log.info (fun f -> f "add client vif %a with IP %a and %d firewall rules"
               Dao.ClientVif.pp vif Ipaddr.V4.pp client_ip (List.length rules));
  Lwt.async (fun () ->
      Lwt.catch (fun () ->
          add_vif vif ~client_ip ~router ~cleanup_tasks rules
        )
        (fun ex ->
           Log.warn (fun f -> f "Error with client %a: %s"
                        Dao.ClientVif.pp vif (Printexc.to_string ex));
           return ()
        )
    );
  cleanup_tasks

(*
let rules_for_client vif =
  match Dao.VifMap.find vif !clients with
  | None -> []
  | Some (ip_addr, rules) -> rules
*)

(** Watch XenStore for notifications of new clients. *)
let listen qubesDB router =
  Dao.watch_clients qubesDB (fun new_set ->
    (* Check for removed clients *)
    !clients |> Dao.VifMap.iter (fun key cleanup ->
      if not (Dao.VifMap.mem key new_set) then (
        clients := !clients |> Dao.VifMap.remove key;
        Log.info (fun f -> f "client %a has gone" Dao.ClientVif.pp key);
        Cleanup.cleanup cleanup
      )
    );
    (* Check for added clients *)
    new_set |> Dao.VifMap.iter (fun key (ip_addr, rules) ->
      if not (Dao.VifMap.mem key !clients) then (
        let cleanup = add_client ~router key ip_addr rules in
        Log.debug (fun f -> f "client %a arrived with %d rules" Dao.ClientVif.pp key (List.length rules));
        clients := !clients |> Dao.VifMap.add key cleanup
      )
    )
  )
