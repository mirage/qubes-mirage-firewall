let src = Logs.Src.create "fw-resolver" ~doc:"Firewall's DNS resolver module"
module Log = (val Logs.src_log src : Logs.LOG)

type t = {
  resolver : Dns_resolver.t ref;
  dns_ports : Ports.PortSet.t ref;
  uplink_ip : Ipaddr.V4.t ;
  get_ptime : unit -> Ptime.t;
  get_mtime : unit -> int64;
}

let handle_buf t proto sender src_port query =
  Dns_resolver.handle_buf !(t.resolver) (t.get_ptime ()) (t.get_mtime ()) true proto sender src_port query

let pick_free_port ~nat_ports ~dns_ports =
  Ports.pick_free_port ~add_list:dns_ports ~consult_list:nat_ports

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

