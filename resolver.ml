let src = Logs.Src.create "fw-resolver" ~doc:"Firewall's DNS resolver module"
module Log = (val Logs.src_log src : Logs.LOG)

module NameMvar = Map.Make(struct
   type t = [`host] Domain_name.t
   let compare = Domain_name.compare
  end)

type t = {
  resolver : Dns_resolver.t;
  (* NOTE: do not try to make this pure, it relies on mvars / side effects *)
  dns_ports : Ports.PortSet.t ref;
  uplink_ip : Ipaddr.V4.t ;
  get_ptime : unit -> Ptime.t;
  get_mtime : unit -> int64;
  get_random : int -> Cstruct.t;
  unknown_names : (int32 * Dns.Rr_map.Ipv4_set.t) list Lwt_mvar.t NameMvar.t ref;
}

let handle_buf t proto sender src_port query =
  Dns_resolver.handle_buf t.resolver (t.get_ptime ()) (t.get_mtime ()) true proto sender src_port query

let pick_free_port ~nat_ports ~dns_ports =
  Ports.pick_free_port ~add_list:dns_ports ~consult_list:nat_ports

let get_mvars_from_packet t (packet : Dns.Packet.t) =
  match packet.data with
  | `Answer ((answers : Dns.Rr_map.t Domain_name.Map.t) , _authorities) ->
    let open Dns in
    let bindings = Domain_name.Map.bindings answers in
    let find_mvar name = NameMvar.find_opt name !(t.unknown_names) in
    (* Return the list of mvars that can be resolved with these answers *)
    List.fold_left (fun acc (k, _) ->
        match Domain_name.host k with
        | Error _ -> acc
        | Ok name ->
          match find_mvar name with
          | Some mvar -> (name, mvar) :: acc
          | None -> acc
      ) [] bindings
  | _ -> []

let answers_for_name name records : (int32 * Dns.Rr_map.Ipv4_set.t) list =
  let open Dns.Packet in
  let get_ip_set acc record =
    let find_me (answer, _authority) =
      Dns.Name_rr_map.find (Domain_name.raw name) Dns.Rr_map.A answer
    in

    match record.data with
    | `Answer maps -> begin match find_me maps with
        | Some q -> q :: acc
        | None -> acc
      end
    | _ -> acc
  in
  let replies = List.fold_left get_ip_set [] records in
  replies

let handle_answers name answers =
  let records = List.map (fun (_, _, _, record) -> record) answers in
  let decode acc packet = match Dns.Packet.decode packet with
    | Error _ -> acc
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
    List.flatten @@ List.map (get_mvars_from_packet t) packets
  in
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
  let query_cstruct, _ = Dns_client.make_query t.get_random `Udp name Dns.Rr_map.A in

  let sender = t.uplink_ip in
  let new_resolver, answers', upstream_queries = Dns_resolver.handle_buf t.resolver p_now ts query_or_reply proto sender src_port query_cstruct in
  let t = { t with resolver = new_resolver } in
  let answers = handle_answers name answers' in
  if answers <> []
  then
    t, `Known answers
  else
    begin
      let mvar = Lwt_mvar.create_empty () in
      t.unknown_names := NameMvar.add name mvar !(t.unknown_names);
      t, `Unknown (mvar, upstream_queries)
    end

let ip_of_reply_packet (name : [`host] Domain_name.t) dns_packet =
  Log.debug (fun f -> f "DNS reply packet: %a" Dns.Packet.pp dns_packet);
  match dns_packet.Dns.Packet.data with
  (* TODO: how should we handle authority? *)
  (* TODO: we need to handle other record types (CNAME, MX) ... *)
  | `Answer (answer, _authority) ->
    begin
      match Dns.Name_rr_map.find (Domain_name.raw name) Dns.Rr_map.A answer with
      | Some q -> Ok q
      | None ->
        (* nethack.alt.org => CNAME someawshostnethack.alt.org
         * in the mvar map, we have an entry with key nethack.alt.org and value some_mvar to wake up
         * but we need to look up someawshostnethack.alt.org (and potentially more cnames beyond it) to get the ipv4 to compare with the packet
         * so we need to have another structure that lets us map further cname responses (like someawshostnethack.alt.org) to the original request
         * *)
        Error `No_A_record
    end
  | _ -> Error  `Not_answer

