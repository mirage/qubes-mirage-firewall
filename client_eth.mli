(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** The ethernet network our client AppVMs are on. *)

open Utils

type t
(** A network for client AppVMs to join. *)

type host =
  [ `Client of client_link
  | `Unknown_client of Ipaddr.t
  | `Client_gateway
  | `External of Ipaddr.t ]

val create : prefix:Ipaddr.V4.Prefix.t -> client_gw:Ipaddr.V4.t -> t
(** [create ~prefix ~client_gw] is a network of client machines.
    Their IP addresses all start with [prefix] and they are configured to
    use [client_gw] as their default gateway. *)

val add_client : t -> client_link -> unit
val remove_client : t -> client_link -> unit

val prefix : t -> Ipaddr.V4.Prefix.t
val client_gw : t -> Ipaddr.V4.t

val classify : t -> Ipaddr.t -> host
val resolve : t -> host -> Ipaddr.t

val lookup : t -> Ipaddr.V4.t -> client_link option

module ARP : sig
  (** We already know the correct mapping of IP addresses to MAC addresses, so we never
      allow clients to update it. We log a warning if a client attempts to set incorrect
      information. *)

  type arp
  (** An ARP-responder for one client. *)

  val create : net:t -> client_link -> arp
  (** [create ~net client_link] is an ARP responder for [client_link].
      It answers on behalf of other clients in [net] (but not for the client
      itself, since the client might be trying to check that its own address is
      free). It also answers for the client's gateway address. *)

  val input : arp -> Cstruct.t -> Cstruct.t option
  (** Process one ethernet frame containing an ARP message.
      Returns a response frame, if one is needed. *)
end
