(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix
open Fw_utils

module Eth = Ethernet.Make(Netif)

let src = Logs.Src.create "uplink" ~doc:"Network connection to NetVM"
module Log = (val Logs.src_log src : Logs.LOG)

module Make (R:Mirage_random.C) (Clock : Mirage_clock_lwt.MCLOCK) = struct
  module Arp = Arp.Make(Eth)(OS.Time)
  module I = Static_ipv4.Make(R)(Clock)(Eth)(Arp)
  module U = Udp.Make(I)(R)

  type t = {
    net : Netif.t;
    eth : Eth.t;
    arp : Arp.t;
    interface : interface;
    ip : I.t;
    udp: U.t;
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

  let send_dns_response t src_port (_, dst, dst_port, buf) =
    Log.debug (fun f -> f "sending dns response");
    U.write ~src_port ~dst ~dst_port t.udp buf >>= function
    | Error s -> Log.err (fun f -> f "error sending udp packet: %a" U.pp_error s); Lwt.return_unit
    | Ok () -> Lwt.return_unit

  let send_dns_query t src_port (_, dst, buf) =
    Log.debug (fun f -> f "sending dns request");
    U.write ~src_port ~dst ~dst_port:53 t.udp buf >>= function
    | Error s -> Log.err (fun f -> f "error sending udp packet: %a" U.pp_error s); Lwt.return_unit
    | Ok () -> Lwt.return_unit

  let listen t resolver router =
    Netif.listen t.net ~header_size:Ethernet_wire.sizeof_ethernet (fun frame ->
        (* Handle one Ethernet frame from NetVM *)
        Eth.input t.eth
          ~arpv4:(Arp.input t.arp)
          ~ipv4:(fun ip ->
              match Nat_packet.of_ipv4_packet ip with
              | exception ex ->
                Log.err (fun f -> f "Error unmarshalling ethernet frame from uplink: %s@.%a" (Printexc.to_string ex)
                            Cstruct.hexdump_pp frame
                        );
                Lwt.return_unit
              | Error e ->
                Log.warn (fun f -> f "Ignored unknown IPv4 message from uplink: %a" Nat_packet.pp_error e);
                Lwt.return ()
              | Ok (`IPv4 (ip_header, ip_packet)) ->
                Log.debug (fun f -> f "received an ipv4 packet from %a on uplink interface" Ipaddr.V4.pp ip_header.Ipv4_packet.src);
                match ip_packet with
                | `UDP (header, packet) when Ports.PortSet.mem header.Udp_packet.dst_port !(resolver.Resolver.dns_ports) ->
                  let state, answers, queries = Resolver.handle_buf resolver `Udp ip_header.Ipv4_packet.src header.Udp_packet.src_port packet in
                  resolver.Resolver.resolver := state;
                  Log.err (fun f -> f "DNS response packet received; removed port %d" header.Udp_packet.dst_port);
                  resolver.Resolver.dns_ports := Ports.PortSet.remove header.Udp_packet.dst_port !(resolver.Resolver.dns_ports);
                  Log.err (fun f -> f "%d further queries are needed and %d answers are ready" (List.length queries) (List.length answers));
                  Lwt_list.iter_s (send_dns_query t (Resolver.pick_free_port ~dns_ports:resolver.Resolver.dns_ports ~nat_ports:router.Router.ports)) queries
                | _ ->
                  Firewall.ipv4_from_netvm resolver router (`IPv4 (ip_header, ip_packet))
            )
          ~ipv6:(fun _ip -> return ())
          frame
      ) >|= or_raise "Uplink listen loop" Netif.pp_error

  let interface t = t.interface

  let connect ~clock config =
    let my_ip = config.Dao.uplink_our_ip in
    let gw = config.Dao.uplink_netvm_ip in
    Netif.connect "0" >>= fun net ->
    Eth.connect net >>= fun eth ->
    Arp.connect eth >>= fun arp ->
    Arp.add_ip arp my_ip >>= fun () ->
    I.connect ~ip:my_ip ~gateway:(Some gw) clock eth arp >>= fun ip ->
    U.connect ip >>= fun udp ->
    let netvm_mac =
      Arp.query arp gw
      >|= or_raise "Getting MAC of our NetVM" Arp.pp_error in
    let interface = new netvm_iface eth netvm_mac
      ~my_ip
      ~other_ip:config.Dao.uplink_netvm_ip in
    return { net; eth; arp; interface; ip; udp }

end
