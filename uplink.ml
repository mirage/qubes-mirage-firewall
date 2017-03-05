(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix
open Fw_utils

module Eth = Ethif.Make(Netif)

let src = Logs.Src.create "uplink" ~doc:"Network connection to NetVM"
module Log = (val Logs.src_log src : Logs.LOG)

module Make(Clock : Mirage_clock_lwt.MCLOCK) = struct
  module Arp = Arpv4.Make(Eth)(Clock)(OS.Time)

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
    method writev ethertype payload =
      FrameQ.send queue (fun () ->
        mac >>= fun dst ->
        let eth_hdr = eth_header ethertype ~src:(Eth.mac eth) ~dst in
        Eth.writev eth (eth_hdr :: payload) >|= or_raise "Write to uplink" Eth.pp_error
      )
  end

  let listen t router =
    Netif.listen t.net (fun frame ->
        (* Handle one Ethernet frame from NetVM *)
        Eth.input t.eth
          ~arpv4:(Arp.input t.arp)
          ~ipv4:(fun ip ->
              match Nat_packet.of_ipv4_packet ip with
              | Error e ->
                Log.warn (fun f -> f "Ignored unknown IPv4 message from uplink: %a" Nat_packet.pp_error e);
                Lwt.return ()
              | Ok packet ->
                Firewall.ipv4_from_netvm router packet
            )
          ~ipv6:(fun _ip -> return ())
          frame
      ) >|= or_raise "Uplink listen loop" Netif.pp_error

  let interface t = t.interface

  let connect ~clock config =
    let ip = config.Dao.uplink_our_ip in
    Netif.connect "0" >>= fun net ->
    Eth.connect net >>= fun eth ->
    Arp.connect eth clock >>= fun arp ->
    Arp.add_ip arp ip >>= fun () ->
    let netvm_mac =
      Arp.query arp config.Dao.uplink_netvm_ip
      >|= or_raise "Getting MAC of our NetVM" Arp.pp_error in
    let interface = new netvm_iface eth netvm_mac
      ~my_ip:ip
      ~other_ip:config.Dao.uplink_netvm_ip in
    return { net; eth; arp; interface }
end
