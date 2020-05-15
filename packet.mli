type port = int

type host =
  [ `Client of Fw_utils.client_link (** an IP address on the private network *)
  | `Firewall (** the firewall's IP on the private network *)
  | `NetVM (** the IP of the firewall's default route *)
  | `External of Ipaddr.t (** an IP on the public network *)
  ]

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

val pp_transport_header : Format.formatter -> transport_header -> unit

val pp_host : Format.formatter -> host -> unit

val to_mirage_nat_packet : ('a, 'b) t -> Nat_packet.t

val of_mirage_nat_packet : src:'a -> dst:'b -> Nat_packet.t -> ('a, 'b) t option

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
