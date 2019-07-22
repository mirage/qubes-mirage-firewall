(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Classify IP packets, apply rules and send as appropriate. *)

val ipv4_from_netvm : Router.t -> Resolver.t -> Nat_packet.t -> unit Lwt.t
(** Handle a packet from the outside world (this module will validate the source IP). *)

val ipv4_from_client : Router.t -> Resolver.t -> src:Fw_utils.client_link -> Nat_packet.t -> unit Lwt.t
(** Handle a packet from a client. Caller must check the source IP matches the client's
    before calling this. *)
