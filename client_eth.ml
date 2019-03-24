(* Copyright (C) 2016, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Fw_utils
open Lwt.Infix

let src = Logs.Src.create "client_eth" ~doc:"Ethernet networks for NetVM clients"
module Log = (val Logs.src_log src : Logs.LOG)

type t = {
  mutable iface_of_ip : client_link IpMap.t;
  changed : unit Lwt_condition.t;   (* Fires when [iface_of_ip] changes. *)
  client_gw : Ipaddr.V4.t;  (* The IP that clients are given as their default gateway. *)
}

type host =
  [ `Client of client_link
  | `Client_gateway
  | `External of Ipaddr.t ]

let create ~client_gw =
  let changed = Lwt_condition.create () in
  { iface_of_ip = IpMap.empty; client_gw; changed }

let client_gw t = t.client_gw

let add_client t iface =
  let ip = iface#other_ip in
  let rec aux () =
    if IpMap.mem ip t.iface_of_ip then (
      (* Wait for old client to disappear before adding one with the same IP address.
         Otherwise, its [remove_client] call will remove the new client instead. *)
      Log.info (fun f -> f "Waiting for old client %a to go away before accepting new one" Ipaddr.V4.pp ip);
      Lwt_condition.wait t.changed >>= aux
    ) else (
      t.iface_of_ip <- t.iface_of_ip |> IpMap.add ip iface;
      Lwt_condition.broadcast t.changed ();
      Lwt.return_unit
    )
  in
  aux ()

let remove_client t iface =
  let ip = iface#other_ip in
  assert (IpMap.mem ip t.iface_of_ip);
  t.iface_of_ip <- t.iface_of_ip |> IpMap.remove ip;
  Lwt_condition.broadcast t.changed ()

let lookup t ip = IpMap.find ip t.iface_of_ip

let classify t ip =
  match ip with
  | Ipaddr.V6 _ -> `External ip
  | Ipaddr.V4 ip4 ->
    if ip4 = t.client_gw then `Client_gateway
    else match lookup t ip4 with
      | Some client_link -> `Client client_link
      | None -> `External ip

let resolve t : host -> Ipaddr.t = function
  | `Client client_link -> Ipaddr.V4 client_link#other_ip
  | `Client_gateway -> Ipaddr.V4 t.client_gw
  | `External addr -> addr

module ARP = struct
  type arp = {
    net : t;
    client_link : client_link;
  }

  let lookup t ip =
    if ip = t.net.client_gw then Some t.client_link#my_mac
    else None
  (* We're now treating client networks as point-to-point links,
     so we no longer respond on behalf of other clients. *)
    (*
    else match IpMap.find ip t.net.iface_of_ip with
    | Some client_iface -> Some client_iface#other_mac
    | None -> None
     *)

  let create ~net client_link = {net; client_link}

  let input_query t arp =
    let req_ipv4 = arp.Arp_packet.target_ip in
    Log.info (fun f -> f "who-has %s?" (Ipaddr.V4.to_string req_ipv4));
    if req_ipv4 = t.client_link#other_ip then (
      Log.info (fun f -> f "ignoring request for client's own IP");
      None
    ) else match lookup t req_ipv4 with
      | None ->
        Log.info (fun f -> f "unknown address; not responding");
        None
      | Some req_mac ->
        Log.info (fun f -> f "responding to: who-has %s?" (Ipaddr.V4.to_string req_ipv4));
        Some { Arp_packet.
               operation = Arp_packet.Reply;
               (* The Target Hardware Address and IP are copied from the request *)
               target_ip = arp.Arp_packet.source_ip;
               target_mac = arp.Arp_packet.source_mac;
               source_ip = req_ipv4;
               source_mac = req_mac;
             }

  let input_gratuitous t arp =
    let source_ip = arp.Arp_packet.source_ip in
    let source_mac = arp.Arp_packet.source_mac in
    match lookup t source_ip with
    | Some real_mac when Macaddr.compare source_mac real_mac = 0 ->
      Log.info (fun f -> f "client suggests updating %s -> %s (as expected)"
                   (Ipaddr.V4.to_string source_ip) (Macaddr.to_string source_mac));
    | Some other_mac ->
      Log.warn (fun f -> f "client suggests incorrect update %s -> %s (should be %s)"
                   (Ipaddr.V4.to_string source_ip) (Macaddr.to_string source_mac) (Macaddr.to_string other_mac));
    | None ->
      Log.warn (fun f -> f "client suggests incorrect update %s -> %s (unexpected IP)"
                   (Ipaddr.V4.to_string source_ip) (Macaddr.to_string source_mac))

  let input t arp =
    let op = arp.Arp_packet.operation in
    match op with
    | Arp_packet.Request -> input_query t arp
    | Arp_packet.Reply -> input_gratuitous t arp; None
end
