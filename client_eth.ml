(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Utils

let src = Logs.Src.create "client_eth" ~doc:"Ethernet for NetVM clients"
module Log = (val Logs.src_log src : Logs.LOG)

type t = {
  mutable iface_of_ip : client_link IpMap.t;
  prefix : Ipaddr.V4.Prefix.t;
  client_gw : Ipaddr.V4.t;  (* The IP that clients are given as their default gateway. *)
}

let create ~prefix ~client_gw =
  { iface_of_ip = IpMap.empty; client_gw; prefix }

let prefix t = t.prefix

let add_client t iface =
  let ip = iface#client_ip in
  assert (Ipaddr.V4.Prefix.mem ip t.prefix);
  (* TODO: Should probably wait for the previous client to disappear. *)
  (* assert (not (IpMap.mem ip t.iface_of_ip)); *)
  t.iface_of_ip <- t.iface_of_ip |> IpMap.add ip iface

let remove_client t iface =
  let ip = iface#client_ip in
  assert (IpMap.mem ip t.iface_of_ip);
  t.iface_of_ip <- t.iface_of_ip |> IpMap.remove ip

let lookup t ip = IpMap.find ip t.iface_of_ip

module ARP = struct
  type arp = {
    net : t;
    client_link : client_link;
  }

  let lookup t ip =
    if ip === t.net.client_gw then Some t.client_link#my_mac
    else match IpMap.find ip t.net.iface_of_ip with
    | Some client_iface -> Some client_iface#client_mac
    | None -> None

  let create ~net client_link = {net; client_link}

  type arp_msg = {
    op: [ `Request |`Reply |`Unknown of int ];
    sha: Macaddr.t;
    spa: Ipaddr.V4.t;
    tha: Macaddr.t;
    tpa: Ipaddr.V4.t;
  }

  let to_wire arp =
    let open Arpv4_wire in
    (* Obtain a buffer to write into *)
    let buf = Cstruct.create (Wire_structs.sizeof_ethernet + sizeof_arp) in
    (* Write the ARP packet *)
    let dmac = Macaddr.to_bytes arp.tha in
    let smac = Macaddr.to_bytes arp.sha in
    let spa = Ipaddr.V4.to_int32 arp.spa in
    let tpa = Ipaddr.V4.to_int32 arp.tpa in
    let op =
      match arp.op with
      |`Request -> 1
      |`Reply -> 2
      |`Unknown n -> n
    in
    Wire_structs.set_ethernet_dst dmac 0 buf;
    Wire_structs.set_ethernet_src smac 0 buf;
    Wire_structs.set_ethernet_ethertype buf 0x0806; (* ARP *)
    let arpbuf = Cstruct.shift buf 14 in
    set_arp_htype arpbuf 1;
    set_arp_ptype arpbuf 0x0800; (* IPv4 *)
    set_arp_hlen arpbuf 6; (* ethernet mac size *)
    set_arp_plen arpbuf 4; (* ipv4 size *)
    set_arp_op arpbuf op;
    set_arp_sha smac 0 arpbuf;
    set_arp_spa arpbuf spa;
    set_arp_tha dmac 0 arpbuf;
    set_arp_tpa arpbuf tpa;
    buf

  let input_query t frame =
    let open Arpv4_wire in
    let req_ipv4 = Ipaddr.V4.of_int32 (get_arp_tpa frame) in
    Log.info "who-has %s?" (fun f -> f (Ipaddr.V4.to_string req_ipv4));
    if req_ipv4 === t.client_link#client_ip then (
      Log.info "ignoring request for client's own IP" Logs.unit;
      None
    ) else match lookup t req_ipv4 with
    | None ->
        Log.info "unknown address; not responding" Logs.unit;
        None
    | Some req_mac ->
        Log.info "responding to: who-has %s?" (fun f -> f (Ipaddr.V4.to_string req_ipv4));
        Some (to_wire {
          op = `Reply;
          (* The Target Hardware Address and IP are copied from the request *)
          tha = Macaddr.of_bytes_exn (copy_arp_sha frame);
          tpa = Ipaddr.V4.of_int32 (get_arp_spa frame);
          sha = req_mac;
          spa = req_ipv4;
        })

  let input_gratuitous t frame =
    let open Arpv4_wire in
    let spa = Ipaddr.V4.of_int32 (get_arp_spa frame) in
    let sha = Macaddr.of_bytes_exn (copy_arp_sha frame) in
    match lookup t spa with
    | Some real_mac when Macaddr.compare sha real_mac = 0 ->
        Log.info "client suggests updating %s -> %s (as expected)"
          (fun f -> f (Ipaddr.V4.to_string spa) (Macaddr.to_string sha));
    | Some other_mac ->
        Log.warn "client suggests incorrect update %s -> %s (should be %s)"
          (fun f -> f (Ipaddr.V4.to_string spa) (Macaddr.to_string sha) (Macaddr.to_string other_mac));
    | None ->
        Log.warn "client suggests incorrect update %s -> %s (unexpected IP)"
          (fun f -> f (Ipaddr.V4.to_string spa) (Macaddr.to_string sha))

  let input t frame =
    match Arpv4_wire.get_arp_op frame with
    |1 -> input_query t frame
    |2 -> input_gratuitous t frame; None
    |n -> Log.warn "unknown message %d - ignored" (fun f -> f n); None
end
