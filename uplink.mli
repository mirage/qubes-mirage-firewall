(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** The link from us to NetVM (and, through that, to the outside world). *)

open Fw_utils

module Make (R: Mirage_random.C)(Clock : Mirage_clock_lwt.MCLOCK) : sig
  type t

  val connect : clock:Clock.t -> Dao.network_config -> t Lwt.t
  (** Connect to our NetVM (gateway). *)

  val interface : t -> interface
  (** The network interface to NetVM. *)

  val listen : t -> Resolver.t -> Router.t -> unit Lwt.t
  (** Handle incoming frames from NetVM. *)
end
