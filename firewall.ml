(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Fw_utils
open Packet
open Lwt.Infix

let src = Logs.Src.create "firewall" ~doc:"Packet handler"
module Log = (val Logs.src_log src : Logs.LOG)

(* Transmission *)

let transmit (ip, payload) iface =
  let packet = Ipv4_packet.Marshal.make_cstruct ~payload ip in
  Lwt.catch
    (fun () -> iface#writev Ethif_wire.IPv4 [packet; payload])
    (fun ex ->
       Log.warn (fun f -> f "Failed to write packet to %a: %s"
                    Ipaddr.V4.pp_hum iface#other_ip
                    (Printexc.to_string ex));
       Lwt.return ()
    )

let forward_ipv4 t (ip, packet) =
  match Router.target t ip with
  | Some iface -> transmit (ip, packet) iface
  | None -> return ()

(* Packet classification *)

let classify_tcp trans =
  match Tcp.Tcp_packet.Unmarshal.of_cstruct trans with
  | Error e ->
    Log.info (fun f -> f "Failed to parse TCP packet: %s" e);
    `Unknown
  | Ok (tcp, _payload) ->
    let sport = tcp.Tcp.Tcp_packet.src_port in
    let dport = tcp.Tcp.Tcp_packet.dst_port in
    `TCP {sport; dport}

let classify_udp trans =
  match Udp_packet.Unmarshal.of_cstruct trans with
  | Error e ->
    Log.info (fun f -> f "Failed to parse UDP packet: %s" e);
    `Unknown
  | Ok (udp, _payload) ->
    let sport = udp.Udp_packet.src_port in
    let dport = udp.Udp_packet.dst_port in
    `UDP {sport; dport}

let classify t (ip, transport) =
  let proto =
    match ip.Ipv4_packet.proto |> Ipv4_packet.Unmarshal.int_to_protocol with
    | Some `ICMP -> `ICMP
    | Some `TCP -> classify_tcp transport
    | Some `UDP -> classify_udp transport
    | None -> `Unknown in
  Some {
    packet = (ip, transport);
    src = Router.classify t (Ipaddr.V4 ip.Ipv4_packet.src);
    dst = Router.classify t (Ipaddr.V4 ip.Ipv4_packet.dst);
    proto;
  }

let pp_ports fmt {sport; dport} =
  Format.fprintf fmt "sport=%d dport=%d" sport dport

let pp_host fmt = function
  | `Client c -> Ipaddr.V4.pp_hum fmt (c#other_ip)
  | `Unknown_client ip -> Format.fprintf fmt "unknown-client(%a)" Ipaddr.pp_hum ip
  | `NetVM -> Format.pp_print_string fmt "net-vm"
  | `External ip -> Format.fprintf fmt "external(%a)" Ipaddr.pp_hum ip
  | `Firewall_uplink -> Format.pp_print_string fmt "firewall(uplink)"
  | `Client_gateway -> Format.pp_print_string fmt "firewall(client-gw)"

let pp_proto fmt = function
  | `UDP ports -> Format.fprintf fmt "UDP(%a)" pp_ports ports
  | `TCP ports -> Format.fprintf fmt "TCP(%a)" pp_ports ports
  | `ICMP -> Format.pp_print_string fmt "ICMP"
  | `Unknown -> Format.pp_print_string fmt "UnknownProtocol"

let pp_packet fmt {src; dst; proto; packet = _} =
  Format.fprintf fmt "[src=%a dst=%a proto=%a]"
    pp_host src
    pp_host dst
    pp_proto proto

(* NAT *)

let translate t packet =
  My_nat.translate t.Router.nat packet

(* Add a NAT rule for the endpoints in this frame, via a random port on the firewall. *)
let add_nat_and_forward_ipv4 t packet =
  let xl_host = Ipaddr.V4 t.Router.uplink#my_ip in
  My_nat.add_nat_rule_and_translate t.Router.nat ~xl_host `Rewrite packet >>= function
  | Ok packet -> forward_ipv4 t packet
  | Error e ->
    Log.warn (fun f -> f "Failed to add NAT rewrite rule: %s" e);
    Lwt.return ()

(* Add a NAT rule to redirect this conversation to [host:port] instead of us. *)
let nat_to t ~host ~port packet =
  let target = Router.resolve t host in
  let xl_host = Ipaddr.V4 t.Router.uplink#my_ip in
  My_nat.add_nat_rule_and_translate t.Router.nat ~xl_host (`Redirect (target, port)) packet >>= function
  | Ok packet -> forward_ipv4 t packet
  | Error e ->
    Log.warn (fun f -> f "Failed to add NAT redirect rule: %s" e);
    Lwt.return ()

(* Handle incoming packets *)

let apply_rules t rules info =
  let packet = info.packet in
  match rules info, info.dst with
  | `Accept, `Client client_link -> transmit packet client_link
  | `Accept, (`External _ | `NetVM) -> transmit packet t.Router.uplink
  | `Accept, (`Firewall_uplink | `Client_gateway) ->
      Log.warn (fun f -> f "Bad rule: firewall can't accept packets %a" pp_packet info);
      return ()
  | `NAT, _ -> add_nat_and_forward_ipv4 t packet
  | `NAT_to (host, port), _ -> nat_to t packet ~host ~port
  | `Drop reason, _ ->
      Log.info (fun f -> f "Dropped packet (%s) %a" reason pp_packet info);
      return ()

let handle_low_memory t =
  match Memory_pressure.status () with
  | `Memory_critical -> (* TODO: should happen before copying and async *)
      Log.warn (fun f -> f "Memory low - dropping packet and resetting NAT table");
      My_nat.reset t.Router.nat >|= fun () ->
      `Memory_critical
  | `Ok -> Lwt.return `Ok

let ipv4_from_client t (ip, payload) =
  handle_low_memory t >>= function
  | `Memory_critical -> return ()
  | `Ok ->
  (* Check for existing NAT entry for this packet *)
  translate t (ip, payload) >>= function
  | Some frame -> forward_ipv4 t frame  (* Some existing connection or redirect *)
  | None ->
  (* No existing NAT entry. Check the firewall rules. *)
  match classify t (ip, payload) with
  | None -> return ()
  | Some info -> apply_rules t Rules.from_client info

let ipv4_from_netvm t (ip, payload) =
  handle_low_memory t >>= function
  | `Memory_critical -> return ()
  | `Ok ->
  match classify t (ip, payload) with
  | None -> return ()
  | Some info ->
  match info.src with
  | `Client _ | `Firewall_uplink | `Client_gateway ->
    Log.warn (fun f -> f "Frame from NetVM has internal source IP address! %a" pp_packet info);
    return ()
  | `External _ | `NetVM ->
  translate t (ip, payload) >>= function
  | Some frame -> forward_ipv4 t frame
  | None ->
  apply_rules t Rules.from_netvm info
