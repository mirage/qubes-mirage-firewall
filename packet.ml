(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Fw_utils

type port = int

type host =
  [ `Client of client_link | `Firewall | `NetVM | `External of Ipaddr.t ]

type transport_header = [`TCP of Tcp.Tcp_packet.t
                        |`UDP of Udp_packet.t
                        |`ICMP of Icmpv4_packet.t]

type ('src, 'dst) t = {
  ipv4_header : Ipv4_packet.t;
  transport_header : transport_header;
  transport_payload : Cstruct.t;
  src : 'src;
  dst : 'dst;
}
let pp_transport_header f = function
  | `ICMP h -> Icmpv4_packet.pp f h
  | `TCP h -> Tcp.Tcp_packet.pp f h
  | `UDP h -> Udp_packet.pp f h

let pp_host fmt = function
  | `Client c -> Ipaddr.V4.pp fmt (c#other_ip)
  | `Unknown_client ip -> Format.fprintf fmt "unknown-client(%a)" Ipaddr.pp ip
  | `NetVM -> Format.pp_print_string fmt "net-vm"
  | `External ip -> Format.fprintf fmt "external(%a)" Ipaddr.pp ip
  | `Firewall -> Format.pp_print_string fmt "firewall(client-gw)"

let to_mirage_nat_packet t : Nat_packet.t =
  match t.transport_header with
  | `TCP h  -> `IPv4 (t.ipv4_header, (`TCP (h, t.transport_payload)))
  | `UDP h  -> `IPv4 (t.ipv4_header, (`UDP (h, t.transport_payload)))
  | `ICMP h -> `IPv4 (t.ipv4_header, (`ICMP (h, t.transport_payload)))

let of_mirage_nat_packet ~src ~dst packet : ('a, 'b) t option =
  let `IPv4 (ipv4_header, ipv4_payload) = packet in
  let transport_header, transport_payload = match ipv4_payload with
    | `TCP (h, p) -> `TCP h, p
    | `UDP (h, p) -> `UDP h, p
    | `ICMP (h, p) -> `ICMP h, p
  in
  Some {
    ipv4_header;
    transport_header;
    transport_payload;
    src;
    dst;
  }

(* possible actions to take for a packet: *)
type action = [
  | `Accept (* Send to destination, unmodified. *)
  | `NAT    (* Rewrite source field to the firewall's IP, with a fresh source port.
               Also, add translation rules for future traffic in both directions,
               between these hosts on these ports, and corresponding ICMP error traffic. *)
  | `NAT_to of host * port (* As for [`NAT], but also rewrite the packet's
                              destination fields so it will be sent to [host:port]. *)
  | `Drop of string (* Drop packet for this reason. *)
]
