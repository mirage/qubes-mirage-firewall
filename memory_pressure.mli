(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

val init : unit -> unit
(** Write current memory usage information to XenStore. *)

val status : unit -> [ `Ok | `Memory_critical ]
(** Check the memory situation. If we're running low, do a GC (work-around for
    http://caml.inria.fr/mantis/view.php?id=7100 and OCaml GC needing to malloc
    extra space to run finalisers). Returns [`Memory_critical] if memory is
    still low - caller should take action to reduce memory use.
    After GC, updates meminfo in XenStore. *)
