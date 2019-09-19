let src = Logs.Src.create "fw-resolver" ~doc:"Firewall's DNS resolver module"
module Log = (val Logs.src_log src : Logs.LOG)

module NameMvar = Map.Make(struct
   type t = [`host] Domain_name.t
   let compare = Domain_name.compare
  end)

type t = {
  (* NOTE: do not try to make this pure; the listen function passed to Netback (and therefore
     constrained to its type interface) needs to return unit, and also can modify this
     resolver state
  *)
  resolver : Dns_resolver.t ref;
  (* NOTE: do not try to make this pure, it relies on mvars / side effects *)
  dns_ports : Ports.PortSet.t ref;
  uplink_ip : Ipaddr.V4.t ;
  get_ptime : unit -> Ptime.t;
  get_mtime : unit -> int64;
  get_random : int -> Cstruct.t;
  unknown_names : (int32 * Dns.Rr_map.Ipv4_set.t) list Lwt_mvar.t NameMvar.t ref;
}

let handle_buf t proto sender src_port query =
  Dns_resolver.handle_buf !(t.resolver) (t.get_ptime ()) (t.get_mtime ()) true proto sender src_port query

let pick_free_port ~nat_ports ~dns_ports =
  Ports.pick_free_port ~add_list:dns_ports ~consult_list:nat_ports

let get_mvars_from_packet t (packet : Dns.Packet.t) =
  let find_mvar name = NameMvar.find_opt name !(t.unknown_names) in
  let (name, _) = packet.question in
  Log.debug (fun f -> f "got a response packet with info for name %a" Domain_name.pp name);
  match Domain_name.host name with
  | Error _ -> []
  | Ok name ->
    match packet.data, find_mvar name with
    | `Rcode_error (NXDomain, _opcode, _), Some mvar ->
      Log.debug (fun f -> f "NXDomain for name %a" Domain_name.pp name);
      Log.debug (fun f -> f "found an mvar for NXDomain %a" Domain_name.pp name);
      Log.err (fun f -> f "Name %a does not exist.  Please replace it with an IP address in the ruleset." Domain_name.pp name);
      (name, mvar) :: []
    | `Rcode_error (NXDomain, _opcode, _), None ->
      Log.debug (fun f -> f "no mvar found for NXDomain %a" Domain_name.pp name);
      []
    | `Answer (answers, _auth) , Some mvar ->
      Log.debug (fun f -> f "found an mvar for A record %a" Domain_name.pp name);
      (name, mvar) :: []
    | `Answer (answers, _auth) , None ->
      Log.debug (fun f -> f "no mvar found for A record %a" Domain_name.pp name);
      []
    | _ -> []

let answers_for_name name records : (int32 * Dns.Rr_map.Ipv4_set.t) list =
  let open Dns.Packet in
  let get_ip_set acc record =
    let find_me record_type (answer, _authority) =
      Dns.Name_rr_map.find (Domain_name.raw name) record_type answer
    in

    match record.data with
    | `Answer maps -> begin match find_me Dns.Rr_map.A maps with
        | Some q ->
          q :: acc
        | None ->  acc
      end
(* TODO: under what circumstances would we get >1 answer for NXDomain?
   Probably in this case we need to sift through the answers for those which
   match the name we looked up. *)
    | `Rcode_error (NXDomain, _, Some (answers, _authorities)) ->
      let (name, _) = record.question in
      Log.debug (fun f -> f "got an NXDomain for name %a" Domain_name.pp name);
      begin
        match Dns.Name_rr_map.find (Domain_name.raw name) Dns.Rr_map.A answers with
        | Some (ttl, _) ->
          (ttl, Dns.Rr_map.Ipv4_set.empty) :: acc
        | None ->
          let ttl = 0l in
          (ttl, Dns.Rr_map.Ipv4_set.empty) :: acc
      end
    | `Rcode_error (NXDomain, _, None) ->
      let (name, _) = record.question in
      Log.debug (fun f -> f "got an NXDomain for name %a with no answers -- faking the TTL" Domain_name.pp name);
      let ttl = 0l in
      (ttl, Dns.Rr_map.Ipv4_set.empty) :: acc
    | _ -> acc
  in
  let replies = List.fold_left get_ip_set [] records in
  replies

let handle_answers name answers =
  let records = List.map (fun (_proto, _ip, _port, record) -> record) answers in
  let decode acc packet = match Dns.Packet.decode packet with
    | Error _ -> Log.debug (fun f -> f "unparseable packet %a in answers; ignoring it" Cstruct.hexdump_pp packet); acc
    | Ok decoded -> decoded :: acc
  in
  let arecord_map = List.fold_left decode [] records in
  Log.debug (fun f -> f "got %d parseable A records answers for name %a" (List.length arecord_map) Domain_name.pp name);
  answers_for_name name arecord_map

let handle_answers_and_notify t answers =
  let records = List.map (fun (_, _, _, record) -> record) answers in

  let decode acc packet = match Dns.Packet.decode packet with
    | Error _ -> acc
    | Ok decoded -> decoded :: acc
  in
  let packets : Dns.Packet.t list = List.fold_left decode [] records in
  (* TODO: remove duplicates from this list, to avoid putting into the same mvar multiple times *)
  let (names_and_mvars : ('a Domain_name.t * 'b Lwt_mvar.t) list) =
    (* I think the resolver needs to help us in this case, and tell us who this NXDomain is associated with. *)
    let the_mvars = List.map (get_mvars_from_packet t) packets in
    List.iter (fun m ->
        Log.debug (fun f -> f "we found %d relevant mvars from the response" (List.length m));
      ) the_mvars;
    List.flatten @@ the_mvars
  in
  Log.debug (fun f -> f "names_and_mvars has len %d, derived from a list of answers of length %d" (List.length names_and_mvars) (List.length answers));
  Lwt_list.iter_p (fun (name, mvar) ->
      let answer = answers_for_name name packets in
      Lwt_mvar.put mvar answer
    ) names_and_mvars

let get_cache_response_or_queries t name =
  (* listener needs no bookkeeping of port number as there is no real network interface traffic, just an in memory call *)
  let src_port = pick_free_port ~nat_ports:(ref Ports.PortSet.empty) ~dns_ports:t.dns_ports in
  let p_now = t.get_ptime () in
  let ts = t.get_mtime () in
  let query_or_reply = true in
  let proto = `Udp in
  (* TODO: check to make sure we're not already waiting to find out about this name, before we potentially make a duplicate mvar *)
  let query_cstruct, _ = Dns_client.make_query t.get_random `Udp name Dns.Rr_map.A in

  let sender = t.uplink_ip in
  let new_resolver, answers', upstream_queries =
    Dns_resolver.handle_buf !(t.resolver) p_now ts query_or_reply proto
      sender src_port query_cstruct in
  t.resolver := new_resolver;
  let answers = handle_answers name answers' in
  if answers <> []
  then
    t, `Known answers
  else
    begin
      match NameMvar.find_opt name !(t.unknown_names) with
      | Some mvar -> 
        Log.debug (fun f -> f "There is already an mvar for %a.  Sending %d more packets to try to resolve it..." Domain_name.pp name (List.length upstream_queries));
        (t, `Unknown (mvar, upstream_queries))
      | None ->
        let mvar = Lwt_mvar.create_empty () in
        t.unknown_names := NameMvar.add name mvar !(t.unknown_names);
        t, `Unknown (mvar, upstream_queries)
    end

let ip_of_reply_packet (name : [`host] Domain_name.t) dns_packet =
  Log.debug (fun f -> f "DNS reply packet: %a" Dns.Packet.pp dns_packet);
  let open Rresult in
  let open Dns in
  (* begin copied code from ocaml-dns client library for following cnames *)
  let rec follow_cname counter q_name answer =
    if counter <= 0 then Error (`Msg "CNAME recursion too deep")
    else
      Domain_name.Map.find_opt q_name answer
      |> R.of_option ~none:(fun () ->
          R.error_msgf "Can't find relevant map in response:@ \
                        %a in [%a]"
            Domain_name.pp q_name
            Name_rr_map.pp answer
        ) >>= fun relevant_map ->
      begin match Rr_map.find A relevant_map with
        | Some response -> Ok response
        | None ->
          begin match Rr_map.(find Cname relevant_map) with
            | None -> Error (`Msg "Invalid DNS response")
            | Some (_ttl, redirected_host) ->
              follow_cname (pred counter) redirected_host answer
          end
      end
      (* end copied code *)
  in
  match dns_packet.Dns.Packet.data with
  (* TODO: how should we handle authority? *)
  | `Rcode_error (NXDomain, _, _) ->
    Log.err (fun f -> f "No DNS record exists for %a. Please manually set an IP address for this rule." Domain_name.pp name);
    Error `Nxdomain
  | `Answer (answer, _authority) ->
    follow_cname 20 (Domain_name.raw name) answer
  | _ -> Error `Not_answer
