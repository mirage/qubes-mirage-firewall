(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Utils

let src = Logs.Src.create "router" ~doc:"Router"
module Log = (val Logs.src_log src : Logs.LOG)

(* The routing table *)

type t = {
  client_eth : Client_eth.t;
  nat : Nat_lookup.t;
  default_gateway : interface;
  my_uplink_ip : Ipaddr.t;
}

let create ~client_eth ~default_gateway ~my_uplink_ip =
  let nat = Nat_lookup.empty () in
  { client_eth; nat; default_gateway; my_uplink_ip }

let target t buf =
  let open Wire_structs.Ipv4_wire in
  let dst_ip = get_ipv4_dst buf |> Ipaddr.V4.of_int32 in
  if Ipaddr.V4.Prefix.mem dst_ip (Client_eth.prefix t.client_eth) then (
    match Client_eth.lookup t.client_eth dst_ip with
    | Some client_link -> Some (client_link :> interface)
    | None ->
      Log.warn "Packet to unknown internal client %a - dropping"
        (fun f -> f Ipaddr.V4.pp_hum dst_ip);
      None
  ) else Some t.default_gateway

let add_client t = Client_eth.add_client t.client_eth
let remove_client t = Client_eth.remove_client t.client_eth

let classify t ip =
  let (===) a b = (Ipaddr.compare a b = 0) in
  if ip === t.my_uplink_ip then `Firewall_uplink
  else (Client_eth.classify t.client_eth ip :> Packet.host)
