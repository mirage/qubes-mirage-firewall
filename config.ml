(* mirage >= 4.5.0 *)
(* Copyright (C) 2017, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Configuration for the "mirage" tool. *)

open Mirage

let nat_table_size = runtime_arg ~pos:__POS__ "Unikernel.nat_table_size"

let main =
    main
    ~runtime_args:[ nat_table_size; ]
    ~packages:[
      package "vchan" ~min:"4.0.2";
      package "cstruct";
      package "astring";
      package "tcpip" ~min:"3.7.0";
      package "arp" ~min:"2.3.0" ~sublibs:["mirage"];
      package "ethernet" ~min:"3.0.0";
      package "shared-memory-ring" ~min:"3.0.0";
      package "netchannel" ~min:"2.1.2";
      package "mirage-net-xen";
      package "ipaddr" ~min:"5.2.0";
      package "mirage-qubes" ~min:"0.9.1";
      package "mirage-nat" ~min:"3.0.1";
      package "mirage-logs";
      package "mirage-xen" ~min:"8.0.0";
      package "dns-client" ~min:"6.4.0";
      package "pf-qubes";
    ]
    "Unikernel.Main" (random @-> mclock @-> time @-> job)

let () =
  register "qubes-firewall" [main $ default_random $ default_monotonic_clock $ default_time]
