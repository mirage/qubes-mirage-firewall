(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Packet
open Lwt.Infix

let src = Logs.Src.create "firewall" ~doc:"Packet handler"
module Log = (val Logs.src_log src : Logs.LOG)

(* Transmission *)

let transmit_ipv4 packet iface =
  Lwt.catch
    (fun () ->
       let fragments = ref [] in
       iface#writev `IPv4 (fun b ->
           match Nat_packet.into_cstruct packet b with
           | Error e ->
             Log.warn (fun f -> f "Failed to write packet to %a: %a"
                          Ipaddr.V4.pp iface#other_ip
                          Nat_packet.pp_error e);
             0
           | Ok (n, frags) -> fragments := frags ; n) >>= fun () ->
       Lwt_list.iter_s (fun f ->
           let size = Cstruct.len f in
           iface#writev `IPv4 (fun b -> Cstruct.blit f 0 b 0 size ; size))
         !fragments)
    (fun ex ->
       Log.warn (fun f -> f "Failed to write packet to %a: %s"
                    Ipaddr.V4.pp iface#other_ip
                    (Printexc.to_string ex));
       Lwt.return_unit
    )

let forward_ipv4 t packet =
  let `IPv4 (ip, _) = packet in
  match Router.target t ip with
  | Some iface -> transmit_ipv4 packet iface
  | None -> Lwt.return_unit

(* NAT *)

let translate t packet =
  My_nat.translate t.Router.nat packet

(* Add a NAT rule for the endpoints in this frame, via a random port on the firewall. *)
let add_nat_and_forward_ipv4 t packet =
  let xl_host = t.Router.uplink#my_ip in
  My_nat.add_nat_rule_and_translate t.Router.nat ~xl_host `NAT packet >>= function
  | Ok packet -> forward_ipv4 t packet
  | Error e ->
    Log.warn (fun f -> f "Failed to add NAT rewrite rule: %s (%a)" e Nat_packet.pp packet);
    Lwt.return_unit

(* Add a NAT rule to redirect this conversation to [host:port] instead of us. *)
let nat_to t ~host ~port packet =
  match Router.resolve t host with
  | Ipaddr.V6 _ -> Log.warn (fun f -> f "Cannot NAT with IPv6"); Lwt.return_unit
  | Ipaddr.V4 target ->
    let xl_host = t.Router.uplink#my_ip in
    My_nat.add_nat_rule_and_translate t.Router.nat ~xl_host (`Redirect (target, port)) packet >>= function
    | Ok packet -> forward_ipv4 t packet
    | Error e ->
      Log.warn (fun f -> f "Failed to add NAT redirect rule: %s (%a)" e Nat_packet.pp packet);
      Lwt.return_unit

let apply_rules t (rules : ('a, 'b) Packet.t -> Packet.action Lwt.t) ~dst (annotated_packet : ('a, 'b) Packet.t) : unit Lwt.t =
  let packet = to_mirage_nat_packet annotated_packet in
  rules annotated_packet >>= fun action ->
  match action, dst with
  | `Accept, `Client client_link -> transmit_ipv4 packet client_link
  | `Accept, (`External _ | `NetVM) -> transmit_ipv4 packet t.Router.uplink
  | `Accept, `Firewall ->
      Log.warn (fun f -> f "Bad rule: firewall can't accept packets %a" Nat_packet.pp packet);
      Lwt.return_unit
  | `NAT, _ ->
      Log.debug (fun f -> f "adding NAT rule for %a" Nat_packet.pp packet);
      add_nat_and_forward_ipv4 t packet
  | `NAT_to (host, port), _ -> nat_to t packet ~host ~port
  | `Drop reason, _ ->
      Log.debug (fun f -> f "Dropped packet (%s) %a" reason Nat_packet.pp packet);
      Lwt.return_unit

let handle_low_memory t =
  match Memory_pressure.status () with
  | `Memory_critical -> (* TODO: should happen before copying and async *)
      Log.warn (fun f -> f "Memory low - dropping packet and resetting NAT table");
      My_nat.reset t.Router.nat >|= fun () ->
      `Memory_critical
  | `Ok -> Lwt.return `Ok

let ipv4_from_client t ~src packet =
  handle_low_memory t >>= function
  | `Memory_critical -> Lwt.return_unit
  | `Ok ->
  (* Check for existing NAT entry for this packet *)
  translate t packet >>= function
  | Some frame -> forward_ipv4 t frame  (* Some existing connection or redirect *)
  | None ->
  (* No existing NAT entry. Check the firewall rules. *)
  let `IPv4 (ip, _transport) = packet in
  let dst = Router.classify t (Ipaddr.V4 ip.Ipv4_packet.dst) in
  match of_mirage_nat_packet ~src:(`Client src) ~dst packet with
  | None -> Lwt.return_unit
  | Some firewall_packet -> apply_rules t Rules.from_client ~dst firewall_packet

let ipv4_from_netvm t packet =
  handle_low_memory t >>= function
  | `Memory_critical -> Lwt.return_unit
  | `Ok ->
  let `IPv4 (ip, _transport) = packet in
  let src = Router.classify t (Ipaddr.V4 ip.Ipv4_packet.src) in
  let dst = Router.classify t (Ipaddr.V4 ip.Ipv4_packet.dst) in
  match Packet.of_mirage_nat_packet ~src ~dst packet with
  | None -> Lwt.return_unit
  | Some _ ->
  match src with
  | `Client _ | `Firewall ->
    Log.warn (fun f -> f "Frame from NetVM has internal source IP address! %a" Nat_packet.pp packet);
    Lwt.return_unit
  | `External _ | `NetVM as src ->
  translate t packet >>= function
  | Some frame -> forward_ipv4 t frame
  | None ->
    match Packet.of_mirage_nat_packet ~src ~dst packet with
    | None -> Lwt.return_unit
    | Some packet -> apply_rules t Rules.from_netvm ~dst packet
