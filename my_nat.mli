(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(* Abstract over NAT interface (todo: remove this) *)

type t

type action = [
  | `NAT
  | `Redirect of Mirage_nat.endpoint
]

val create : max_entries:int -> t Lwt.t
val reset : t -> unit Lwt.t
val remove_connections : t -> Ipaddr.V4.t -> unit
val translate : t -> Nat_packet.t -> Nat_packet.t option Lwt.t
val add_nat_rule_and_translate : t ->
  xl_host:Ipaddr.V4.t -> action -> Nat_packet.t -> (Nat_packet.t, string) result Lwt.t
