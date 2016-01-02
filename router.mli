(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Routing packets to the right network interface. *)

open Utils

type t = private {
  client_eth : Client_eth.t;
  mutable nat : Nat_lookup.t;
  uplink : interface;
}
(** A routing table. *)

val create :
  client_eth:Client_eth.t ->
  uplink:interface ->
  t
(** [create ~client_eth ~uplink] is a new routing table
    that routes packets outside of [client_eth] via [uplink]. *)

val target : t -> Cstruct.t -> interface option
(** [target t packet] is the interface to which [packet] (an IP packet) should be routed. *)

val add_client : t -> client_link -> unit
(** [add_client t iface] adds a rule for routing packets addressed to [iface].
    The client's IP address must be within the [client_eth] passed to [create]. *)

val remove_client : t -> client_link -> unit

val classify : t -> Ipaddr.t -> Packet.host
val resolve : t -> Packet.host -> Ipaddr.t

val reset : t -> unit
(** Clear the NAT table (to free memory). *)
