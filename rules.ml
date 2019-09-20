(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** This module applies firewall rules from QubesDB. *)

open Packet
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

  let matches_proto rule packet = match rule.Pf_qubes.Parse_qubes.proto, rule.Pf_qubes.Parse_qubes.specialtarget with
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
        match rule.Pf_qubes.Parse_qubes.icmp_type with
        | None -> true
        | Some rule_icmp_type ->
          0 = compare rule_icmp_type @@ Icmpv4_wire.ty_to_int header.Icmpv4_packet.ty
      end
      | _, _ -> false

  let matches_dest resolver rule packet =
    let ip = packet.ipv4_header.Ipv4_packet.dst in
    match rule.Pf_qubes.Parse_qubes.dst with
    | `any ->  `Match rule
    | `hosts subnet ->
      if (Ipaddr.Prefix.mem Ipaddr.(V4 ip) subnet) then `Match rule else `No_match
    | `dnsname name ->
      match Resolver.get_cache_response_or_queries resolver name with
      | t, `Unknown (condition, queries) -> `Lookup_and_retry (t, condition, queries)
      | _t, `Known answers ->
        Log.debug (fun f -> f "resolver has cache entries for %a" Domain_name.pp name);
        let find = Dns.Rr_map.Ipv4_set.mem in
        (* we don't need to check the ttl ourselves, because the resolver expires it given the information that Resolver.get_cache_response_or_queries passes to it *)
        if List.exists (fun (_ttl, ipset) -> find ip ipset) answers
        then `Match rule
        else `No_match

end

let find_first_match resolver packet acc rule =
  match acc with | `No_match ->
                   if Classifier.matches_proto rule packet then Classifier.matches_dest resolver rule packet else begin
                     Log.debug (fun f -> f "rule %d is not a match - proto" rule.Q.number);
                     `No_match
                   end
                 | q -> q
 
(* Does the packet match our rules? *)
let classify_client_packet resolver (packet : ([`Client of Fw_utils.client_link], _) Packet.t)  =
  let (`Client client_link) = packet.src in
  let rules = snd client_link#get_rules in
  match List.fold_left (find_first_match resolver packet) `No_match rules with
  | `No_match -> `Drop "No matching rule; assuming default drop"
  | `Match {Q.action = Q.Accept; _} -> `Accept
  | `Match ({Q.action = Q.Drop; number; _} as rule) -> 
    `Drop (Format.asprintf "rule number %a explicitly drops this packet" Q.pp_rule rule)
  | `Lookup_and_retry q -> `Lookup_and_retry q

(** Packets from the private interface that don't match any NAT table entry are being checked against the fw rules here *)
let from_client resolver (packet : ([`Client of Fw_utils.client_link], _) Packet.t) : Packet.action =
  match packet with
  | { dst = `Client_gateway; transport_header = `UDP header; _ } ->
    if header.Udp_packet.dst_port = dns_port
    then `NAT_to (`NetVM, dns_port)
    else `Drop "packet addressed to client gateway"
  | { dst = `External _ ; _ } | { dst = `NetVM; _ }-> begin
    (* see whether this traffic is allowed *)
    match classify_client_packet resolver packet with
    | `Accept -> `NAT
    | `Drop s -> `Drop s
    | `Lookup_and_retry q -> `Lookup_and_retry q
  end
  | { dst = (`Client_gateway | `Firewall_uplink) ; _ } -> `Drop "packet addressed to firewall itself"
  | { dst = `Client _ ; _ } -> classify_client_packet resolver packet
  | _ -> `Drop "could not classify packet"

(** Packets from the outside world that don't match any NAT table entry are being dropped by default *)
let from_netvm (_packet : ([`NetVM | `External of _], _) Packet.t) : Packet.action =
  `Drop "drop by default"
