(* Copyright (C) 2016, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Keep track of the queue length for output buffers. *)

type t

val create : string -> t
(** [create name] is a new empty queue. [name] is used in log messages. *)

val send : t -> (unit -> 'a Lwt.t) -> 'a Lwt.t
(** [send t fn] checks that the queue isn't overloaded and calls [fn ()] if it's OK.
    The item is considered to be queued until the result of [fn] has resolved.
    In the case of mirage-net-xen's [writev], this happens when the frame has been
    added to the ring (not when it is consumed), which is fine for us. *)
