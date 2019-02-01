(* Copyright (C) 2017, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Configuration for the "mirage" tool. *)

open Mirage

let table_size =
  let open Functoria_key in
  let info = Arg.info
      ~doc:"The number of NAT entries to allocate."
      ~docv:"ENTRIES" ["nat-table-size"]
  in
  let key = Arg.opt ~stage:`Both Arg.int 5_000 info in
  create "nat_table_size" key

let main =
  foreign
    ~keys:[Functoria_key.abstract table_size]
    ~packages:[
      package "vchan";
      package "cstruct";
      package "astring";
      package "tcpip" ~sublibs:["stack-direct"; "xen"; "arpv4"] ~min:"3.1.0";
      package "shared-memory-ring" ~min:"3.0.0";
      package "netchannel" ~min:"1.8.0";
      package "mirage-net-xen" ~min:"1.7.1";
      package "ipaddr" ~min:"3.0.0";
      package "mirage-qubes";
      package "mirage-nat";
      package "mirage-logs";
    ]
    "Unikernel.Main" (mclock @-> job)

let () =
  register "qubes-firewall" [main $ default_monotonic_clock]
    ~argv:no_argv
