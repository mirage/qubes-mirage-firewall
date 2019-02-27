(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Put your firewall rules in this file. *)

open Packet   (* Allow us to use definitions in packet.ml *)

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
let classify_client_packet (info : ([`Client of _], _) Packet.info) rules : Packet.action =
  let matches_port dstports (port : int) =
    List.exists (fun (Q.Range_inclusive (min, max)) -> (min <= port && port <= max)) dstports
  in
  let matches_proto rule packet = match rule.Pf_qubes.Parse_qubes.proto with
    | None -> true
    | Some p ->
      match p, packet.transport_header with
      | `tcp, `TCP header -> matches_port rule.Q.dstports header.dst_port
      | `udp, `UDP header -> matches_port rule.Q.dstports header.dst_port
      | `icmp, `ICMP header -> true (* TODO *)
      | _, _ -> false 
  in
  let matches_dest rule info = match rule.Pf_qubes.Parse_qubes.dst with
    | `any -> true
    | `hosts subnet -> 
      let (`IPv4 (header, _ )) = info.Packet.packet in
      Ipaddr.Prefix.mem (V4 header.Ipv4_packet.dst) subnet
  in
  let action = List.fold_left (fun found rule -> match found with 
      | Some action -> Some action 
      | None -> if matches_proto rule info && matches_dest rule info then Some rule.action else None) None rules
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
let from_client (info : ([`Client of _], _) Packet.info) : Packet.action =
  match info with
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
    match classify_client_packet info dummy_rules with
    | `Accept -> `NAT
    | `Drop s -> `Drop s
    end
  | { dst = `Client_gateway; proto = `UDP { dport = 53 } } -> `NAT_to (`NetVM, 53)
  | { dst = (`Client_gateway | `Firewall_uplink) } -> `Drop "packet addressed to firewall itself"
  | { dst = `Client _ } -> classify_client_packet info dummy_rules

(** Decide what to do with a packet received from the outside world.
    Note: If the packet matched an existing NAT rule then this isn't called. *)
let from_netvm (info : ([`NetVM | `External of _], _) Packet.info) : Packet.action =
  match info with
  | _ -> `Drop "drop by default"
