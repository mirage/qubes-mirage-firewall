(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(* Abstract over NAT interface (todo: remove this) *)

type t

type action = [
  | `NAT
  | `Redirect of Mirage_nat.endpoint
]

val create : get_time:(unit -> Mirage_nat.time) -> max_entries:int -> t Lwt.t
val reset : t -> Ports.PortSet.t ref -> unit Lwt.t
val translate : t -> Nat_packet.t -> Nat_packet.t option Lwt.t
val add_nat_rule_and_translate : t -> Ports.PortSet.t ref -> Resolver.t ->
  xl_host:Ipaddr.V4.t -> action -> Nat_packet.t -> (Nat_packet.t, string) result Lwt.t
