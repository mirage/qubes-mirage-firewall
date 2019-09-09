(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Enforce firewall rules from QubesDB. *)

open Packet
module Q = Pf_qubes.Parse_qubes

let src = Logs.Src.create "rules" ~doc:"Firewall rules"
module Log = (val Logs.src_log src : Logs.LOG)

(* these nameservers are the "specialtarget" ones --
   the upstream NetVM will redirect TCP and UDP port 53 traffic with
   these IPs as destinations to whatever it thinks its upstream nameserver
   should be. *)
let specialtarget_nameservers = [
  Ipaddr.V4.of_string_exn "10.139.1.1";
  Ipaddr.V4.of_string_exn "10.139.1.2";
]
let dns_port = 53

(* OCaml normally warns if you don't match all fields, but that's OK here. *)
[@@@ocaml.warning "-9"]

(* we want to replace this list with a structure including rules from QubesDB.
   we need:
   1) code for reading the rules (we have some for noticing new clients: dao.ml)
   2) code for parsing the rules (use ocaml-pf, reduced to the Qubes ruleset)
   3) code for putting the rules in a structure readable here (???)
   - also the rules are per-client, so the current structure doesn't really accommodate them
   - there is a structure tracking each client in Client_eth, which is using a map from IP addresses to
     Fw_utils.client_link.  let's try putting the rules in this client_link structure?
   - initially we can set them up with a list, and then look for faster/better/clearer structures later
   4) code for applying the rules to incoming traffic (below, already in this file)
   *)

(* Does the packet match our rules? *)
let classify_client_packet resolver _router (packet : ([`Client of Fw_utils.client_link], _) Packet.t)  : Packet.action =
  let matches_port dstports (port : int) = match dstports with
    | None -> true
    | Some (Q.Range_inclusive (min, max)) -> min <= port && port <= max
  in
  let matches_proto rule packet = match rule.Pf_qubes.Parse_qubes.proto, rule.Pf_qubes.Parse_qubes.specialtarget with
    | None, None -> true
    | None, Some `dns when List.mem packet.ipv4_header.Ipv4_packet.dst specialtarget_nameservers -> begin
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
  in
  (* return here becomes | Match | No_match | Needs_lookup * Domain_name.t *)
  let matches_dest rule packet =
    let ip = packet.ipv4_header.Ipv4_packet.dst in
    match rule.Pf_qubes.Parse_qubes.dst with
    | `any ->  `Match rule
    | `hosts subnet ->
      if (Ipaddr.Prefix.mem Ipaddr.(V4 ip) subnet) then `Match rule else `No_match
    | `dnsname name ->
      match Hashtbl.find_opt name resolver.cache with
      | None -> `Needs_lookup (mvar, name)
      | Some ip' -> if Ipaddr.V4.compare ip ip' = 0 then `Match else `No_match
  in
  let (`Client client_link) = packet.src in
  let rules = snd client_link#get_rules in
  Log.debug (fun f -> f "checking %d rules for a match" (List.length rules));
  List.fold_left (fun acc rule ->
      match acc with | `Match rule -> `Match rule
                     | `Needs_lookup q -> `Needs_lookup q
                     | `No_match ->
                       if not (matches_proto rule packet) then begin
                         Log.debug (fun f -> f "rule %d is not a match - proto" rule.Q.number);
                         `No_match
                       end
                       else
                         match (matches_dest rule packet) with
                         | `No_match ->
                           Log.debug (fun f -> f "rule %d is not a match - dest" rule.Q.number);
                           `No_match
                         | `Match rule ->
                           Log.debug (fun f -> f "rule %d is a match - dest" rule.Q.number);
                           `Match rule
                         | `Needs_lookup q ->
                           Log.debug (fun f -> f "rule %d needs lookup - dest" rule.Q.number);
                           `Needs_lookup q
                       ) `No_match rules |> function
  | `No_match -> `Drop "No matching rule; assuming default drop"
  | `Match {Q.action = Q.Accept; number; _} ->
    Log.debug (fun f -> f "allowing packet matching rule %d" number);
    `Accept
  | `Match {Q.action = Q.Drop; number; _} ->
    `Drop (Printf.sprintf "rule %d explicitly drops this packet" number)
  | `Needs_lookup q ->
    Log.debug ( fun f -> f "asking for lookup of packet: needs_lookup -> lookup_and_retry");
    `Lookup_and_retry q

(** This function decides what to do with a packet from a client VM.

    It takes as input an argument [info] (of type [Packet.info]) describing the
    packet, and returns an action (of type [Packet.action]) to perform.

    See packet.ml for the definitions of [info] and [action].

    Note: If the packet matched an existing NAT rule then this isn't called. *)
let from_client resolver router (packet : ([`Client of Fw_utils.client_link], _) Packet.t) : Packet.action =
  match packet with
  | { dst = (`External _ | `NetVM) } -> begin
    (* see whether this traffic is allowed *)
    match classify_client_packet resolver router packet with
    | `Accept -> `NAT
    | `Drop s -> `Drop s
    | `Lookup_and_retry q -> `Lookup_and_retry q
  end
  | { dst = `Client_gateway; transport_header = `UDP header; _ } ->
    if header.Udp_packet.dst_port = dns_port
    then `NAT_to (`NetVM, dns_port)
    else `Drop "packet addressed to client gateway"
  | { dst = (`Client_gateway | `Firewall_uplink) } -> `Drop "packet addressed to firewall itself"
  | { dst = `Client _ } -> classify_client_packet resolver router packet

(** Decide what to do with a packet received from the outside world.
    Note: If the packet matched an existing NAT rule then this isn't called. *)
let from_netvm (packet : ([`NetVM | `External of _], _) Packet.t) : Packet.action =
  match packet with
  | _ -> `Drop "drop by default"
