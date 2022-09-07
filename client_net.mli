(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Handling client VMs. *)

val listen : (unit -> int64) ->
  ([ `host ] Domain_name.t -> (int32 * Ipaddr.V4.Set.t, [> `Msg of string ]) result Lwt.t) ->
  Ipaddr.V4.t list -> Qubes.DB.t -> Router.t -> 'a Lwt.t
(** [listen get_timestamp resolver dns_servers db router] is a thread that watches for clients being added to and
    removed from XenStore. Clients are connected to the client network and
    packets are sent via [router]. We ensure the source IP address is correct
    before routing a packet. *)
