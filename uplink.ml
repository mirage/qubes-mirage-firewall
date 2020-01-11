(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix
open Fw_utils

module Eth = Ethernet.Make(Netif)

let src = Logs.Src.create "uplink" ~doc:"Network connection to NetVM"
module Log = (val Logs.src_log src : Logs.LOG)

module Make(Clock : Mirage_clock_lwt.MCLOCK) = struct
  module Arp = Arp.Make(Eth)(OS.Time)

  type t = {
    net : Netif.t;
    eth : Eth.t;
    arp : Arp.t;
    interface : interface;
    fragments : Fragments.Cache.t;
  }

  class netvm_iface eth mac ~my_ip ~other_ip : interface = object
    val queue = FrameQ.create (Ipaddr.V4.to_string other_ip)
    method my_mac = Eth.mac eth
    method my_ip = my_ip
    method other_ip = other_ip
    method writev ethertype fillfn =
      FrameQ.send queue (fun () ->
        mac >>= fun dst ->
        Eth.write eth dst ethertype fillfn >|= or_raise "Write to uplink" Eth.pp_error
      )
  end

  let listen t get_ts router =
    Netif.listen t.net ~header_size:Ethernet_wire.sizeof_ethernet (fun frame ->
        (* Handle one Ethernet frame from NetVM *)
        Eth.input t.eth
          ~arpv4:(Arp.input t.arp)
          ~ipv4:(fun ip ->
              match Nat_packet.of_ipv4_packet t.fragments ~now:(get_ts ()) ip with
              | exception ex ->
                Log.err (fun f -> f "Error unmarshalling ethernet frame from uplink: %s@.%a" (Printexc.to_string ex)
                            Cstruct.hexdump_pp frame
                        );
                Lwt.return_unit
              | Error e ->
                Log.warn (fun f -> f "Ignored unknown IPv4 message from uplink: %a" Nat_packet.pp_error e);
                Lwt.return_unit
              | Ok None -> Lwt.return_unit
              | Ok (Some packet) ->
                Firewall.ipv4_from_netvm router packet
            )
          ~ipv6:(fun _ip -> Lwt.return_unit)
          frame
      ) >|= or_raise "Uplink listen loop" Netif.pp_error

  let interface t = t.interface

  let connect config =
    let ip = config.Dao.uplink_our_ip in
    Netif.connect "0" >>= fun net ->
    Eth.connect net >>= fun eth ->
    Arp.connect eth >>= fun arp ->
    Arp.add_ip arp ip >>= fun () ->
    let netvm_mac =
      Arp.query arp config.Dao.uplink_netvm_ip
      >|= or_raise "Getting MAC of our NetVM" Arp.pp_error in
    let interface = new netvm_iface eth netvm_mac
      ~my_ip:ip
      ~other_ip:config.Dao.uplink_netvm_ip in
    let fragments = Fragments.Cache.create (256 * 1024) in
    Lwt.return { net; eth; arp; interface ; fragments }
end
