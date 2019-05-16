(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Put your firewall rules in this file. *)

open Packet   (* Allow us to use definitions in packet.ml *)

let dns_port = 53

(* List your AppVM IP addresses here if you want to match on them in the rules below.
   Any client not listed here will appear as [`Client `Unknown]. *)
let clients = [
  (*
  "10.137.0.12", `Dev;
  "10.137.0.14", `Untrusted;
  *)
]

(* List your external (non-AppVM) IP addresses here if you want to match on them in the rules below.
   Any external machine not listed here will appear as [`External `Unknown]. *)
let externals = [
  (*
  "8.8.8.8", `GoogleDNS;
  *)
]

(* OCaml normally warns if you don't match all fields, but that's OK here. *)
[@@@ocaml.warning "-9"]

module Q = Pf_qubes.Parse_qubes

let dummy_rules =
  Pf_qubes.Parse_qubes.([{ action = Drop ;
    proto = None ;
    specialtarget = None ;
    dst = `any ;
    dstports = [] ;
    icmp_type = None ;
    number = 0 ;
   }])

(* Does the packet match our rules? *)
let classify_client_packet (packet : ([`Client of _], _) Packet.t) rules : Packet.action =
  let matches_port dstports (port : int) =
    List.exists (fun (Q.Range_inclusive (min, max)) -> (min <= port && port <= max)) dstports
  in
  let matches_proto rule packet = match rule.Pf_qubes.Parse_qubes.proto with
    | Some rule_proto -> match rule_proto, packet.transport_header with
      | `tcp, `TCP header -> matches_port rule.Q.dstports header.dst_port
      | `udp, `UDP header -> matches_port rule.Q.dstports header.dst_port
      | `icmp, `ICMP header -> 
      begin
        match rule.icmp_type with
        | None -> true
        | Some rule_icmp_type -> 
          Icmpv4_wire.ty_to_int header.ty == rule_icmp_type
      end
      | _, _ -> false 
  in
  let matches_dest rule packet = match rule.Pf_qubes.Parse_qubes.dst with
    | `any -> true
    | `hosts subnet -> 
      Ipaddr.Prefix.mem (V4 packet.ipv4_header.Ipv4_packet.dst) subnet
  in
  let action = List.fold_left (fun found rule -> match found with 
      | Some action -> Some action 
      | None -> if matches_proto rule packet && matches_dest rule packet then Some rule.action else None) None rules
  in
  match action with
  | None -> `Drop "No matching rule"
  | Some Accept -> `Accept
  | Some Drop -> `Drop "Drop rule matched"


(** This function decides what to do with a packet from a client VM.

    It takes as input an argument [info] (of type [Packet.info]) describing the
    packet, and returns an action (of type [Packet.action]) to perform.

    See packet.ml for the definitions of [info] and [action].

    Note: If the packet matched an existing NAT rule then this isn't called. *)
let from_client (packet : ([`Client of _], _) Packet.t) : Packet.action =
  match packet with
  (* Examples (add your own rules here):

     1. Allows Dev to send SSH packets to Untrusted.
        Note: responses are not covered by this!
     2. Allows Untrusted to reply to Dev.
     3. Blocks an external site.

     In all cases, make sure you've added the VM name to [clients] or [externals] above, or it won't
     match anything! *)
  (*
  | { src = `Client `Dev; dst = `Client `Untrusted; proto = `TCP { dport = 22 } } -> `Accept
  | { src = `Client `Untrusted; dst = `Client `Dev; proto = `TCP _; packet }
                                        when not (is_tcp_start packet) -> `Accept
  | { dst = `External `GoogleDNS } -> `Drop "block Google DNS"
  *)
  | { dst = (`External _ | `NetVM) } -> 
    begin
    match classify_client_packet packet dummy_rules with
    | `Accept -> `NAT
    | `Drop s -> `Drop s
    end
  | { dst = `Client_gateway; transport_header = `UDP header; _ } ->
    if header.dst_port = dns_port
    then `NAT_to (`NetVM, dns_port)
    else `Drop "packet addressed to client gateway"
  | { dst = (`Client_gateway | `Firewall_uplink) } -> `Drop "packet addressed to firewall itself"
  | { dst = `Client _ } -> classify_client_packet packet dummy_rules

(** Decide what to do with a packet received from the outside world.
    Note: If the packet matched an existing NAT rule then this isn't called. *)
let from_netvm (packet : ([`NetVM | `External of _], _) Packet.t) : Packet.action =
  match packet with
  | _ -> `Drop "drop by default"
