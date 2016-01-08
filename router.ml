(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Utils

let src = Logs.Src.create "router" ~doc:"Router"
module Log = (val Logs.src_log src : Logs.LOG)

(* The routing table *)

type t = {
  client_eth : Client_eth.t;
  mutable nat : Nat_lookup.t;
  uplink : interface;
}

let create ~client_eth ~uplink =
  let nat = Nat_lookup.empty () in
  { client_eth; nat; uplink }

let target t buf =
  let open Wire_structs.Ipv4_wire in
  let dst_ip = get_ipv4_dst buf |> Ipaddr.V4.of_int32 in
  if Ipaddr.V4.Prefix.mem dst_ip (Client_eth.prefix t.client_eth) then (
    match Client_eth.lookup t.client_eth dst_ip with
    | Some client_link -> Some (client_link :> interface)
    | None ->
      Log.warn (fun f -> f "Packet to unknown internal client %a - dropping"
        Ipaddr.V4.pp_hum dst_ip);
      None
  ) else Some t.uplink

let add_client t = Client_eth.add_client t.client_eth
let remove_client t = Client_eth.remove_client t.client_eth

let classify t ip =
  if ip = Ipaddr.V4 t.uplink#my_ip then `Firewall_uplink
  else if ip = Ipaddr.V4 t.uplink#other_ip then `NetVM
  else (Client_eth.classify t.client_eth ip :> Packet.host)

let resolve t = function
  | `Firewall_uplink -> Ipaddr.V4 t.uplink#my_ip
  | `NetVM -> Ipaddr.V4 t.uplink#other_ip
  | #Client_eth.host as host -> Client_eth.resolve t.client_eth host

let reset t =
  t.nat <- Nat_lookup.empty ()
