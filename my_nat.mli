(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(* Abstract over NAT interface (todo: remove this) *)

type t

type action = [
  | `Rewrite
  | `Redirect of Ipaddr.t * int
]

val create : (module Mirage_nat.S with type t = 'a and type config = 'c) -> 'c -> t Lwt.t
val reset : t -> unit Lwt.t
val translate : t -> Nat_packet.t -> Nat_packet.t option Lwt.t
val add_nat_rule_and_translate : t -> xl_host:Ipaddr.t ->
  action -> Nat_packet.t -> (Nat_packet.t, string) result Lwt.t
