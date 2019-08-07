let src = Logs.Src.create "fw-resolver" ~doc:"Firewall's DNS resolver module"
module Log = (val Logs.src_log src : Logs.LOG)

module NameMvar = Map.Make(struct
   type t = [`host] Domain_name.t
   let compare = Domain_name.compare
  end)

type t = {
  resolver : Dns_resolver.t ref;
  dns_ports : Ports.PortSet.t ref;
  uplink_ip : Ipaddr.V4.t ;
  get_ptime : unit -> Ptime.t;
  get_mtime : unit -> int64;
  unknown_names : (int32 * Dns.Rr_map.Ipv4_set.t) Lwt_mvar.t NameMvar.t ref;
}

let handle_buf t proto sender src_port query =
  Dns_resolver.handle_buf !(t.resolver) (t.get_ptime ()) (t.get_mtime ()) true proto sender src_port query

let pick_free_port ~nat_ports ~dns_ports =
  Ports.pick_free_port ~add_list:dns_ports ~consult_list:nat_ports

let handle_answers name answers =
  Log.info (fun f -> f "sitting on %d answers" (List.length answers));
  let records = List.map (fun (_, _, _, record) -> record) answers in

  let answers_for_us us records =
    let open Dns.Packet in
    let get_ip_set acc record =
      let find_me (answer, authority) =
        Dns.Name_rr_map.find (Domain_name.of_string_exn "robur.io") Dns.Rr_map.A answer
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
  in
  let decode acc packet = match Dns.Packet.decode packet with
    | Error _ -> acc
    | Ok decoded -> decoded :: acc
  in
  let arecord_map = List.fold_left decode [] records in
  answers_for_us name arecord_map

let get_cache_response_or_queries t name =
  (* listener needs no bookkeeping of port number as there is no real network interface traffic, just an in memory call *)
  let src_port = pick_free_port ~nat_ports:(ref Ports.PortSet.empty) ~dns_ports:t.dns_ports in
  let p_now = t.get_ptime () in
  let ts = t.get_mtime () in
  let query_or_reply = true in
  let proto = `Udp in
  let query_cstruct, _ = Dns_client.make_query `Udp (Domain_name.of_string_exn name) Dns.Rr_map.A in

  let sender = t.uplink_ip in

  let new_resolver, answers', upstream_queries = Dns_resolver.handle_buf !(t.resolver) p_now ts query_or_reply proto sender src_port query_cstruct in
  t.resolver := new_resolver;
  let answers = handle_answers answers' in
  if answers <> []
  then
    `Known answers
  else
    begin
      let mvar = Lwt_mvar.create_empty () in
      t.unknown_names := NameMvar.add name mvar !(t.unknown_names);
      `Unknown (mvar, upstream_queries)
    end

let ip_of_reply_packet (name : [`host] Domain_name.t) reply_data =
  match Dns.Packet.decode reply_data with
  | Error e -> Error (Fmt.strf "couldn't decode dns reply: %a" Dns.Packet.pp_err e)
  | Ok dns_packet ->
    Log.debug (fun f -> f "DNS reply packet: %a" Dns.Packet.pp dns_packet);
    match dns_packet.data with
    | `Answer (map1, map2) ->
      (* module Answer : sig type t = Name_rr_map.t * Name_rr_map.t *)
      begin
      match Dns.Name_rr_map.find (Domain_name.raw name) Dns.Rr_map.A map1 with
      | Some q -> Ok q
      | None ->
        match Dns.Name_rr_map.find (Domain_name.raw name) Dns.Rr_map.A map2 with
        | None -> Error "maps didn't have an A record for domain name"
        | Some q -> Ok q
      end
    | _ -> Error "this is not an answer"

