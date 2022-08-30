(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** This module applies firewall rules from QubesDB. *)

open Packet
open Lwt.Infix
module Q = Pf_qubes.Parse_qubes

let src = Logs.Src.create "rules" ~doc:"Firewall rules"
module Log = (val Logs.src_log src : Logs.LOG)

(* the upstream NetVM will redirect TCP and UDP port 53 traffic with
   these destination IPs to its upstream nameserver. *)
let default_dns_servers = [
  Ipaddr.V4.of_string_exn "10.139.1.1";
  Ipaddr.V4.of_string_exn "10.139.1.2";
]
let dns_port = 53

module Classifier = struct

  let matches_port dstports (port : int) = match dstports with
    | None -> true
    | Some (Q.Range_inclusive (min, max)) -> min <= port && port <= max

  let matches_proto rule packet = match rule.Q.proto, rule.Q.specialtarget with
    | None, None -> true
    | None, Some `dns when List.mem packet.ipv4_header.Ipv4_packet.dst default_dns_servers -> begin
      (* specialtarget=dns applies only to the specialtarget destination IPs, and
         specialtarget=dns is also implicitly tcp/udp port 53 *)
      match packet.transport_header with
        | `TCP header -> header.Tcp.Tcp_packet.dst_port = dns_port
        | `UDP header -> header.Udp_packet.dst_port = dns_port
        | _ -> false
      end
   (* DNS rules can only match traffic headed to the specialtarget hosts, so any other destination
   isn't a match for DNS rules *)
    | None, Some `dns -> false
    | Some rule_proto, _ -> match rule_proto, packet.transport_header with
      | `tcp, `TCP header -> matches_port rule.Q.dstports header.Tcp.Tcp_packet.dst_port
      | `udp, `UDP header -> matches_port rule.Q.dstports header.Udp_packet.dst_port
      | `icmp, `ICMP header ->
      begin
        match rule.Q.icmp_type with
        | None -> true
        | Some rule_icmp_type ->
          0 = compare rule_icmp_type @@ Icmpv4_wire.ty_to_int header.Icmpv4_packet.ty
      end
      | _, _ -> false

  let matches_dest dns_client rule packet =
    let ip = packet.ipv4_header.Ipv4_packet.dst in
    match rule.Q.dst with
    | `any ->  Lwt.return @@ `Match rule
    | `hosts subnet ->
      Lwt.return @@ if (Ipaddr.Prefix.mem Ipaddr.(V4 ip) subnet) then `Match rule else `No_match
    | `dnsname name ->
      Log.debug (fun f -> f "Resolving %a" Domain_name.pp name);
      dns_client name >|= function
      | Ok (_ttl, found_ips) ->
        if Ipaddr.V4.Set.mem ip found_ips
        then `Match rule
        else `No_match
      | Error (`Msg m) ->
        Log.warn (fun f -> f "Ignoring rule %a, could not resolve" Q.pp_rule rule);
        Log.debug (fun f -> f "%s" m);
        `No_match
      | Error _ -> assert false (* TODO: fix type of dns_client so that this case can go *)

end

let find_first_match dns_client packet acc rule =
  match acc with
  | `No_match ->
    if Classifier.matches_proto rule packet
    then Classifier.matches_dest dns_client rule packet
    else Lwt.return `No_match
  | q -> Lwt.return q

(* Does the packet match our rules? *)
let classify_client_packet dns_client (packet : ([`Client of Fw_utils.client_link], _) Packet.t)  =
  let (`Client client_link) = packet.src in
  let rules = client_link#get_rules in
  Lwt_list.fold_left_s (find_first_match dns_client packet) `No_match rules >|= function
  | `No_match -> `Drop "No matching rule; assuming default drop"
  | `Match {Q.action = Q.Accept; _} -> `Accept
  | `Match ({Q.action = Q.Drop; _} as rule) ->
    `Drop (Format.asprintf "rule number %a explicitly drops this packet" Q.pp_rule rule)

let translate_accepted_packets dns_client packet =
  classify_client_packet dns_client packet >|= function
  | `Accept -> `NAT
  | `Drop s -> `Drop s

(** Packets from the private interface that don't match any NAT table entry are being checked against the fw rules here *)
let from_client dns_client (packet : ([`Client of Fw_utils.client_link], _) Packet.t) : Packet.action Lwt.t =
  match packet with
  | { dst = `External _ ; _ } | { dst = `NetVM; _ } -> translate_accepted_packets dns_client packet
  | { dst = `Firewall ; _ } -> Lwt.return @@ `Drop "packet addressed to firewall itself"
  | { dst = `Client _ ; _ } -> classify_client_packet dns_client packet
  | _ -> Lwt.return @@ `Drop "could not classify packet"

(** Packets from the outside world that don't match any NAT table entry are being dropped by default *)
let from_netvm (_packet : ([`NetVM | `External of _], _) Packet.t) : Packet.action Lwt.t =
  Lwt.return @@ `Drop "drop by default"
