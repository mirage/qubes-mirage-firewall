(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Utils
open Packet

let src = Logs.Src.create "firewall" ~doc:"Packet handler"
module Log = (val Logs.src_log src : Logs.LOG)

(* Transmission *)

let transmit ~frame iface =
  let packet = Cstruct.shift frame Wire_structs.sizeof_ethernet in
  iface#writev [packet]

let forward_ipv4 t frame =
  let packet = Cstruct.shift frame Wire_structs.sizeof_ethernet in
  match Router.target t packet with
  | Some iface -> iface#writev [packet]
  | None -> return ()

(* Packet classification *)

let ports transport =
  let sport, dport = Nat_rewrite.ports_of_transport transport in
  { sport; dport }

let classify t frame =
  match Nat_rewrite.layers frame with
  | None ->
      Log.warn "Failed to parse frame" Logs.unit;
      None
  | Some (_eth, ip, transport) ->
  let src, dst = Nat_rewrite.addresses_of_ip ip in
  let proto =
    match Nat_rewrite.proto_of_ip ip with
    | 1 -> `ICMP
    | 6 -> `TCP (ports transport)
    | 17 -> `UDP (ports transport)
    | _ -> `Unknown in
  Some {
    frame;
    src = Router.classify t src;
    dst = Router.classify t dst;
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

let pp_packet fmt {src; dst; proto; frame = _} =
  Format.fprintf fmt "[src=%a dst=%a proto=%a]"
    pp_host src
    pp_host dst
    pp_proto proto

(* NAT *)

let translate t frame =
  match Nat_rewrite.translate t.Router.nat frame with
  | None -> None
  | Some frame -> Some (fixup_checksums frame |> Cstruct.concat)

let random_user_port () =
  1024 + Random.int (0xffff - 1024)

let rec add_nat_rule_and_transmit t frame fn fmt logf =
  let xl_port = random_user_port () in
  match fn xl_port with
  | Nat_rewrite.Overlap -> add_nat_rule_and_transmit t frame fn fmt logf (* Try a different port *)
  | Nat_rewrite.Unparseable ->
      Log.warn "Failed to add NAT rule: Unparseable" Logs.unit;
      return ()
  | Nat_rewrite.Ok _ ->
      Log.info fmt (logf xl_port);
      match translate t frame with
      | Some frame -> forward_ipv4 t frame
      | None ->
          Log.warn "No NAT entry, even after adding one!" Logs.unit;
          return ()

(* Add a NAT rule for the endpoints in this frame, via a random port on the firewall. *)
let add_nat_and_forward_ipv4 t ~frame =
  let xl_host = Ipaddr.V4 t.Router.uplink#my_ip in
  add_nat_rule_and_transmit t frame
    (Nat_rewrite.make_nat_entry t.Router.nat frame xl_host)
    "added NAT entry: %s:%d -> firewall:%d -> %d:%s"
    (fun xl_port f ->
      match Nat_rewrite.layers frame with
      | None -> assert false
      | Some (_eth, ip, transport) ->
      let src, dst = Nat_rewrite.addresses_of_ip ip in
      let sport, dport = Nat_rewrite.ports_of_transport transport in
      f (Ipaddr.to_string src) sport xl_port dport (Ipaddr.to_string dst)
    )

(* Add a NAT rule to redirect this conversation to [host:port] instead of us. *)
let nat_to t ~frame ~host ~port =
  let gw = Router.resolve t host in
  let xl_host = Ipaddr.V4 t.Router.uplink#my_ip in
  add_nat_rule_and_transmit t frame
    (fun xl_port ->
      Nat_rewrite.make_redirect_entry t.Router.nat frame (xl_host, xl_port) (gw, port)
    )
    "added NAT redirect %s:%d -> %d:firewall:%d -> %d:NetVM"
    (fun xl_port f ->
      match Nat_rewrite.layers frame with
      | None -> assert false
      | Some (_eth, ip, transport) ->
      let src, _dst = Nat_rewrite.addresses_of_ip ip in
      let sport, dport = Nat_rewrite.ports_of_transport transport in
      f (Ipaddr.to_string src) sport dport xl_port port
    )

(* Handle incoming packets *)

let apply_rules t rules info =
  match rules info, info.dst with
  | `Accept, `Client client_link -> transmit ~frame:info.frame client_link
  | `Accept, (`External _ | `NetVM) -> transmit ~frame:info.frame t.Router.uplink
  | `Accept, `Unknown_client _ ->
      Log.warn "Dropping packet to unknown client %a" (fun f -> f pp_packet info);
      return ()
  | `Accept, (`Firewall_uplink | `Client_gateway) ->
      Log.warn "Bad rule: firewall can't accept packets %a" (fun f -> f pp_packet info);
      return ()
  | `NAT, _ -> add_nat_and_forward_ipv4 t ~frame:info.frame
  | `NAT_to (host, port), _ -> nat_to t ~frame:info.frame ~host ~port
  | `Drop reason, _ ->
      Log.info "Dropped packet (%s) %a" (fun f -> f reason pp_packet info);
      return ()

let ipv4_from_client t frame =
  match Memory_pressure.status () with
  | `Memory_critical -> (* TODO: should happen before copying and async *)
      Log.warn "Memory low - dropping packet" Logs.unit;
      return ()
  | `Ok ->
  (* Check for existing NAT entry for this packet *)
  match translate t frame with
  | Some frame -> forward_ipv4 t frame  (* Some existing connection or redirect *)
  | None ->
  (* No existing NAT entry. Check the firewall rules. *)
  match classify t frame with
  | None -> return ()
  | Some info -> apply_rules t Rules.from_client info

let ipv4_from_netvm t frame =
  match Memory_pressure.status () with
  | `Memory_critical -> (* TODO: should happen before copying and async *)
      Log.warn "Memory low - dropping packet" Logs.unit;
      return ()
  | `Ok ->
  match classify t frame with
  | None -> return ()
  | Some info ->
  match info.src with
  | `Client _ | `Unknown_client _ | `Firewall_uplink | `Client_gateway ->
    Log.warn "Frame from NetVM has internal source IP address! %a" (fun f -> f pp_packet info);
    return ()
  | `External _ | `NetVM ->
  match translate t frame with
  | Some frame -> forward_ipv4 t frame
  | None ->
  apply_rules t Rules.from_netvm info
