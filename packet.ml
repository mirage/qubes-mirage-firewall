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
