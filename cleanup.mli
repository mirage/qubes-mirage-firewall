(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Register actions to take when a resource is finished. Like [Lwt_switch], but
    synchronous. *)

type t

val create : unit -> t

val on_cleanup : t -> (unit -> unit) -> unit
(** Register a new action to take on cleanup. *)

val cleanup : t -> unit
(** Run cleanup tasks, starting with the most recently added. *)
