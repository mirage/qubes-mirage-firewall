(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Fw_utils

(* The routing table *)

type t = {
  client_eth : Client_eth.t;
  nat : My_nat.t;
  uplink : interface;
  dns_sender: int -> (Dns.proto * Ipaddr.V4.t * Cstruct.t) -> unit Lwt.t;
  ports : Ports.PortSet.t ref;
}

let create ~client_eth ~uplink ~dns_sender ~nat =
  { client_eth; nat; uplink; dns_sender; ports = ref Ports.PortSet.empty }

let target t buf =
  let dst_ip = buf.Ipv4_packet.dst in
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
