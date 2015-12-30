(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Configuration for the "mirage" tool. *)

open Mirage

let main =
  foreign
    ~libraries:["mirage-net-xen"; "tcpip.stack-direct"; "tcpip.xen"; "mirage-qubes"; "mirage-nat"]
    ~packages:["vchan"; "cstruct"; "tcpip"; "mirage-net-xen"; "mirage-qubes"; "mirage-nat"]
    "Unikernel.Main" (clock @-> job)

let () =
  register "qubes-firewall" [main $ default_clock]
