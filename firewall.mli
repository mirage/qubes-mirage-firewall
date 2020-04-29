(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Classify IP packets, apply rules and send as appropriate. *)

val ipv4_from_netvm : Router.t -> Nat_packet.t -> unit Lwt.t
(** Handle a packet from the outside world (this module will validate the source IP). *)

(* TODO the function type is a workaround, rework the module dependencies / functors to get rid of it *)
val ipv4_from_client : ([ `host ] Domain_name.t -> (int32 * Dns.Rr_map.Ipv4_set.t, [> `Msg of string ]) result Lwt.t) ->
  Router.t -> src:Fw_utils.client_link -> Nat_packet.t -> unit Lwt.t
(** Handle a packet from a client. Caller must check the source IP matches the client's
    before calling this. *)
