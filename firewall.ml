(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Utils
open Packet

let src = Logs.Src.create "firewall" ~doc:"Packet handler"
module Log = (val Logs.src_log src : Logs.LOG)

(* Transmission *)

let transmit ~frame iface =
  (* If packet has been NAT'd then we certainly need to recalculate the checksum,
     but even for direct pass-through it might have been received with an invalid
     checksum due to checksum offload. For now, recalculate full checksum in all
     cases. *)
  let frame = fixup_checksums frame |> Cstruct.concat in
  let packet = Cstruct.shift frame Wire_structs.sizeof_ethernet in
  Lwt.catch
    (fun () -> iface#writev [packet])
    (fun ex ->
       Log.warn (fun f -> f "Failed to write packet to %a: %s"
                    Ipaddr.V4.pp_hum iface#other_ip
                    (Printexc.to_string ex));
       Lwt.return ()
    )

let forward_ipv4 t frame =
  let packet = Cstruct.shift frame Wire_structs.sizeof_ethernet in
  match Router.target t packet with
  | Some iface -> transmit ~frame iface
  | None -> return ()

(* Packet classification *)

let ports transport =
  let sport, dport = Nat_rewrite.ports_of_transport transport in
  { sport; dport }

let classify t frame =
  match Nat_rewrite.layers frame with
  | None ->
      Log.warn (fun f -> f "Failed to parse frame");
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
  Nat_rewrite.translate t.Router.nat frame

let random_user_port () =
  1024 + Random.int (0xffff - 1024)

let rec add_nat_rule_and_transmit ?(retries=100) t frame fn logf =
  let xl_port = random_user_port () in
  match fn xl_port with
  | exception Out_of_memory ->
      (* Because hash tables resize in big steps, this can happen even if we have a fair
         chunk of free memory. *)
      Log.warn (fun f -> f "Out_of_memory adding NAT rule. Dropping NAT table...");
      Router.reset t;
      add_nat_rule_and_transmit ~retries:(retries - 1) t frame fn logf
  | Nat_rewrite.Overlap when retries < 0 -> return ()
  | Nat_rewrite.Overlap ->
      if retries = 0 then (
        Log.warn (fun f -> f "Failed to find a free port; resetting NAT table");
        Router.reset t;
      );
      add_nat_rule_and_transmit ~retries:(retries - 1) t frame fn logf (* Try a different port *)
  | Nat_rewrite.Unparseable ->
      Log.warn (fun f -> f "Failed to add NAT rule: Unparseable");
      return ()
  | Nat_rewrite.Ok _ ->
      Log.debug (logf xl_port);
      match translate t frame with
      | Some frame -> forward_ipv4 t frame
      | None ->
          Log.warn (fun f -> f "No NAT entry, even after adding one!");
          return ()

(* Add a NAT rule for the endpoints in this frame, via a random port on the firewall. *)
let add_nat_and_forward_ipv4 t ~frame =
  let xl_host = Ipaddr.V4 t.Router.uplink#my_ip in
  add_nat_rule_and_transmit t frame
    (* Note: DO NOT partially apply; [t.nat] may change between calls *)
    (fun xl_port -> Nat_rewrite.make_nat_entry t.Router.nat frame xl_host xl_port)
    (fun xl_port f ->
      match Nat_rewrite.layers frame with
      | None -> assert false
      | Some (_eth, ip, transport) ->
      let src, dst = Nat_rewrite.addresses_of_ip ip in
      let sport, dport = Nat_rewrite.ports_of_transport transport in
      f "added NAT entry: %s:%d -> firewall:%d -> %d:%s" (Ipaddr.to_string src) sport xl_port dport (Ipaddr.to_string dst)
    )

(* Add a NAT rule to redirect this conversation to [host:port] instead of us. *)
let nat_to t ~frame ~host ~port =
  let target = Router.resolve t host in
  let xl_host = Ipaddr.V4 t.Router.uplink#my_ip in
  add_nat_rule_and_transmit t frame
    (fun xl_port ->
      Nat_rewrite.make_redirect_entry t.Router.nat frame (xl_host, xl_port) (target, port)
    )
    (fun xl_port f ->
      match Nat_rewrite.layers frame with
      | None -> assert false
      | Some (_eth, ip, transport) ->
      let src, _dst = Nat_rewrite.addresses_of_ip ip in
      let sport, dport = Nat_rewrite.ports_of_transport transport in
      f "added NAT redirect %s:%d -> %d:firewall:%d -> %d:%a"
        (Ipaddr.to_string src) sport dport xl_port port pp_host host
    )

(* Handle incoming packets *)

let apply_rules t rules info =
  let frame = info.frame in
  match rules info, info.dst with
  | `Accept, `Client client_link -> transmit ~frame client_link
  | `Accept, (`External _ | `NetVM) -> transmit ~frame t.Router.uplink
  | `Accept, (`Firewall_uplink | `Client_gateway) ->
      Log.warn (fun f -> f "Bad rule: firewall can't accept packets %a" pp_packet info);
      return ()
  | `NAT, _ -> add_nat_and_forward_ipv4 t ~frame
  | `NAT_to (host, port), _ -> nat_to t ~frame ~host ~port
  | `Drop reason, _ ->
      Log.info (fun f -> f "Dropped packet (%s) %a" reason pp_packet info);
      return ()

let handle_low_memory t =
  match Memory_pressure.status () with
  | `Memory_critical -> (* TODO: should happen before copying and async *)
      Log.warn (fun f -> f "Memory low - dropping packet and resetting NAT table");
      Router.reset t;
      `Memory_critical
  | `Ok -> `Ok

let ipv4_from_client t frame =
  match handle_low_memory t with
  | `Memory_critical -> return ()
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
  match handle_low_memory t with
  | `Memory_critical -> return ()
  | `Ok ->
  match classify t frame with
  | None -> return ()
  | Some info ->
  match info.src with
  | `Client _ | `Firewall_uplink | `Client_gateway ->
    Log.warn (fun f -> f "Frame from NetVM has internal source IP address! %a" pp_packet info);
    return ()
  | `External _ | `NetVM ->
  match translate t frame with
  | Some frame -> forward_ipv4 t frame
  | None ->
  apply_rules t Rules.from_netvm info
