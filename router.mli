(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Routing packets to the right network interface. *)

open Utils

type t
(** A routing table. *)

val create :
  client_net:Client_net.t ->
  default_gateway:interface ->
  t
(** [create ~client_net ~default_gateway] is a new routing table that routes packets outside
    of [client_net] to [default_gateway]. *)

val client_net : t -> Client_net.t

val target : t -> Cstruct.t -> interface option
(** [target t packet] is the interface to which [packet] (an IP packet) should be routed. *)

val add_client : t -> client_link -> unit
(** [add_client t iface] adds a rule for routing packets addressed to [iface].
    The client's IP address must be within the [client_net] passed to [create]. *)

val remove_client : t -> client_link -> unit
