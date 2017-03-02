(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(* Abstract over NAT interface (todo: remove this) *)

type t

type action = [
  | `Rewrite
  | `Redirect of Ipaddr.t * int
]

type packet = Ipv4_packet.t * Cstruct.t

val create : (module Mirage_nat.S with type t = 'a and type config = 'c) -> 'c -> t Lwt.t
val reset : t -> unit Lwt.t
val translate : t -> packet -> packet option Lwt.t
val add_nat_rule_and_translate : t -> xl_host:Ipaddr.t ->
  action -> packet -> (packet, string) result Lwt.t
