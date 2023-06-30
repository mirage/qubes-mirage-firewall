(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Fw_utils

(* The routing table *)

type t = {
  clients : Client_eth.t;
  nat : My_nat.t;
  uplink : interface;
}

let create ~clients ~uplink ~nat =
  { clients; nat; uplink }

let target t buf =
  let dst_ip = buf.Ipv4_packet.dst in
  match Client_eth.lookup t.clients dst_ip with
  | Some client_link -> Some (client_link :> interface)
  | None -> Some t.uplink

let add_client t = Client_eth.add_client t.clients
let remove_client t = Client_eth.remove_client t.clients

let classify t ip =
  if ip = Ipaddr.V4 t.uplink#my_ip then `Firewall
  else if ip = Ipaddr.V4 t.uplink#other_ip then `NetVM
  else (Client_eth.classify t.clients ip :> Packet.host)

let resolve t = function
  | `Firewall -> Ipaddr.V4 t.uplink#my_ip
  | `NetVM -> Ipaddr.V4 t.uplink#other_ip
  | #Client_eth.host as host -> Client_eth.resolve t.clients host
