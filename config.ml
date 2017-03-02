(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Configuration for the "mirage" tool. *)

open Mirage

let main =
  foreign
    ~packages:[
      package "vchan";
      package "cstruct";
      package "tcpip" ~sublibs:["stack-direct"; "xen"];
      package "mirage-net-xen";
      package "mirage-qubes";
      package "mirage-nat" ~sublibs:["hashtable"];
      package "mirage-logs";
    ]
    "Unikernel.Main" (mclock @-> job)

let () =
  register "qubes-firewall" [main $ default_monotonic_clock]
    ~argv:no_argv
