(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(* Abstract over NAT interface (todo: remove this) *)

type t
type action = [ `NAT | `Redirect of Mirage_nat.endpoint ]

val free_udp_port :
  t ->
  src:Ipaddr.V4.t ->
  dst:Ipaddr.V4.t ->
  dst_port:int ->
  int * (unit -> unit)

val dns_port : t -> int -> bool
val create : max_entries:int -> t
val remove_connections : t -> Ipaddr.V4.t -> unit
val translate : t -> Nat_packet.t -> Nat_packet.t option

val add_nat_rule_and_translate :
  t ->
  xl_host:Ipaddr.V4.t ->
  action ->
  Nat_packet.t ->
  (Nat_packet.t, string) result
