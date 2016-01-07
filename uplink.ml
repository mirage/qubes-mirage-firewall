(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix
open Utils

module Eth = Ethif.Make(Netif)

let src = Logs.Src.create "uplink" ~doc:"Network connection to NetVM"
module Log = (val Logs.src_log src : Logs.LOG)

module Make(Clock : V1.CLOCK) = struct
  module Arp = Arpv4.Make(Eth)(Clock)(OS.Time)
  module IPv4 = Ipv4.Make(Eth)(Arp)

  type t = {
    net : Netif.t;
    eth : Eth.t;
    arp : Arp.t;
    interface : interface;
  }

  class netvm_iface eth mac ~my_ip ~other_ip : interface = object
    val queue = FrameQ.create (Ipaddr.V4.to_string other_ip)
    method my_mac = Eth.mac eth
    method my_ip = my_ip
    method other_ip = other_ip
    method writev ip =
      FrameQ.send queue (fun () ->
        mac >>= fun dst ->
        let eth_hdr = eth_header_ipv4 ~src:(Eth.mac eth) ~dst in
        Eth.writev eth (eth_hdr :: ip)
      )
  end

  let listen t router =
    Netif.listen t.net (fun frame ->
      (* Handle one Ethernet frame from NetVM *)
      Eth.input t.eth
        ~arpv4:(Arp.input t.arp)
        ~ipv4:(fun _ip -> Firewall.ipv4_from_netvm router frame)
        ~ipv6:(fun _ip -> return ())
        frame
    )

  let interface t = t.interface

  let connect config =
    let ip = config.Dao.uplink_our_ip in
    Netif.connect "tap0" >>= or_fail "Can't connect uplink device" >>= fun net ->
    Eth.connect net >>= or_fail "Can't make Ethernet device for tap" >>= fun eth ->
    Arp.connect eth >>= or_fail "Can't add ARP" >>= fun arp ->
    Arp.add_ip arp ip >>= fun () ->
    let netvm_mac = Arp.query arp config.Dao.uplink_netvm_ip >|= function
      | `Timeout -> failwith "ARP timeout getting MAC of our NetVM"
      | `Ok netvm_mac -> netvm_mac in
    let interface = new netvm_iface eth netvm_mac
      ~my_ip:ip
      ~other_ip:config.Dao.uplink_netvm_ip in
    return { net; eth; arp; interface }
end
