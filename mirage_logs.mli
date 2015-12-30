(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Mirage support for Logs library. *)

module Make (Clock : V1.CLOCK) : sig
  val init_logging : unit -> unit
  (** [init_logging ()] configures the Logs library to log to stderr,
      with time-stamps provided by [Clock].
      If logs are written faster than the backend can consume them,
      the whole unikernel will block until there is space (so log messages
      will not be lost, but unikernels generating a lot of log output
      may run slowly). *)
end
