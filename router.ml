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
  match Client_eth.lookup t.client_eth dst_ip with
  | Some client_link -> Some (client_link :> interface)
  | None -> Some t.uplink

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

(* To avoid needing to allocate a new NAT table when we've run out of
   memory, pre-allocate the new one ahead of time. *)
let next_nat = ref (Nat_lookup.empty ())
let reset t =
  t.nat <- !next_nat;
  (* (at this point, the big old NAT table can be GC'd, so allocating
     a new one should be OK) *)
  next_nat := Nat_lookup.empty ()
