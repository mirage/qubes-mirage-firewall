(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Utils

type port = int

type ports = {
  sport : port; (* Source port *)
  dport : port; (* Destination *)
}

type host = 
  [ `Client of client_link | `Client_gateway | `Firewall_uplink | `NetVM | `External of Ipaddr.t ]

type info = {
  frame : Cstruct.t;
  src : host;
  dst : host;
  proto : [ `UDP of ports | `TCP of ports | `ICMP | `Unknown ];
}
