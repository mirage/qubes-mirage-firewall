(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Fw_utils

type port = int

type ports = {
  sport : port; (* Source port *)
  dport : port; (* Destination *)
}

type host = 
  [ `Client of client_link | `Client_gateway | `Firewall_uplink | `NetVM | `External of Ipaddr.t ]

(* Note: 'a is either [host], or the result of applying [Rules.clients] and [Rules.externals] to a host. *)
type 'a info = {
  packet : Nat_packet.t;
  src : 'a;
  dst : 'a;
  proto : [ `UDP of ports | `TCP of ports | `ICMP | `Unknown ];
}

(* The first message in a TCP connection has SYN set and ACK clear. *)
let is_tcp_start = function
  | `IPv4 (_ip, `TCP (hdr, _body)) -> Tcp.Tcp_packet.(hdr.syn && not hdr.ack)
  | _ -> false

(* The possible actions we can take for a packet: *)
type action = [
  | `Accept (* Send the packet to its destination. *)
  | `NAT    (* Rewrite the packet's source field so packet appears to
               have come from the firewall, via an unused port.
               Also, add NAT rules so related packets will be translated accordingly. *)
  | `NAT_to of host * port (* As for [`NAT], but also rewrite the packet's
                              destination fields so it will be sent to [host:port]. *)
  | `Drop of string (* Drop the packet and log the given reason. *)
]
