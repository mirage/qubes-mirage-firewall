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
let classify_client_packet resolver router (packet : ([`Client of Fw_utils.client_link], _) Packet.t)  : Packet.action =
  let matches_port dstports (port : int) = match dstports with
    | None -> true
    | Some (Q.Range_inclusive (min, max)) -> min <= port && port <= max
  in
  let matches_proto rule packet = match rule.Pf_qubes.Parse_qubes.proto, rule.Pf_qubes.Parse_qubes.specialtarget with
    | None, None -> true
    | None, Some `dns -> begin
      (* specialtarget=dns applies only to the specialtarget destination IPs, and
         specialtarget=dns is also implicitly tcp/udp port 53 *)
      match packet.transport_header with
        | `TCP header -> header.dst_port = dns_port && List.mem packet.ipv4_header.dst specialtarget_nameservers
        | `UDP header -> header.dst_port = dns_port && List.mem packet.ipv4_header.dst specialtarget_nameservers
        | _ -> false
    end
    | Some rule_proto, _ -> match rule_proto, packet.transport_header with
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
  (* return here becomes | Match | No_match | Needs_lookup * Domain_name.t *)
  let matches_dest rule packet = match rule.Pf_qubes.Parse_qubes.dst with
    | `any ->  `Match rule
    | `hosts subnet ->
      if (Ipaddr.Prefix.mem (V4 packet.ipv4_header.Ipv4_packet.dst) subnet) then `Match rule else `No_match
    | `dnsname name ->
      let open Lwt.Infix in
      let proto = `Udp in (* TODO: this could be TCP too, but we assume UDP for now *)
      let query_or_reply = true in
      let dns_handler, reply_packets, query_packets =
        let src_port = Resolver.pick_free_port ~nat_ports:router.Router.ports ~dns_ports:resolver.Resolver.dns_ports in
        let query, _ = Dns_client.make_query proto name Dns.Rr_map.A in (* TODO: the query could be MX, AAAA, etc instead of A :/ *)
        Resolver.handle_buf resolver proto resolver.uplink_ip src_port query
      in
      resolver.resolver := dns_handler;
      Log.debug (fun f -> f "asking DNS resolver about address %a..." Domain_name.pp name);
      match query_packets, reply_packets with
      | queries, _ when List.length queries > 0 ->
        List.iter (fun (proto, addr, _buf) ->
            Log.debug ( fun f -> f "DNS resolver says to go ask %a about %a" Ipaddr.V4.pp addr Domain_name.pp name)
          ) queries;
        `Needs_lookup queries
      | _, (proto, addr,  _port, reply_data)::tl -> begin
          match Resolver.ip_of_reply_packet name reply_data with
          | Ok (_, ips) ->
            if Dns.Rr_map.Ipv4_set.mem packet.ipv4_header.Ipv4_packet.dst ips
            then `Match rule
            else `No_match
          | Error s -> Log.err (fun f -> f "%s" s); `No_match
      end
      | [], [] -> (* TODO: what does this mean?  I think it means we need to look up the name, but we don't know how *)
        Log.warn (fun f -> f "couldn't resolve the DNS name %a -- please consider changing this rule to refer to an IP address" Domain_name.pp name);
        `No_match
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
  | `Match {Q.action = Accept; number; _} ->
    Log.debug (fun f -> f "allowing packet matching rule %d" number);
    `Accept
  | `Match {Q.action = Drop; number; _} ->
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
    if header.dst_port = dns_port
    then `NAT_to (`NetVM, dns_port)
    else `Drop "packet addressed to client gateway"
  | { dst = (`Client_gateway | `Firewall_uplink) } -> `Drop "packet addressed to firewall itself"
  | { dst = `Client _ } -> classify_client_packet resolver router packet

(** Decide what to do with a packet received from the outside world.
    Note: If the packet matched an existing NAT rule then this isn't called. *)
let from_netvm (packet : ([`NetVM | `External of _], _) Packet.t) : Packet.action =
  match packet with
  | _ -> `Drop "drop by default"
