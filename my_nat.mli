(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(* Abstract over NAT interface (todo: remove this) *)

type ports = private {
  nat_tcp : Ports.t ref;
  nat_udp : Ports.t ref;
  nat_icmp : Ports.t ref;
  dns_udp : Ports.t ref;
}

val empty_ports : unit -> ports

type t

type action = [
  | `NAT
  | `Redirect of Mirage_nat.endpoint
]

val create : max_entries:int -> t
val reset : t -> ports -> unit
val remove_connections : t -> ports -> Ipaddr.V4.t -> unit
val translate : t -> Nat_packet.t -> Nat_packet.t option
val add_nat_rule_and_translate : t -> ports ->
  xl_host:Ipaddr.V4.t -> action -> Nat_packet.t -> (Nat_packet.t, string) result
