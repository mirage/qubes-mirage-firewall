(* Copyright (C) 2017, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Configuration for the "mirage" tool. *)

open Mirage

let table_size =
  let info = Key.Arg.info
      ~doc:"The number of NAT entries to allocate."
      ~docv:"ENTRIES" ["nat-table-size"]
  in
  let key = Key.Arg.opt ~stage:`Both Key.Arg.int 5_000 info in
  Key.create "nat_table_size" key

let main =
  foreign
    ~keys:[Key.v table_size]
    ~packages:[
      package "vchan" ~min:"4.0.2";
      package "cstruct";
      package "astring";
      package "tcpip" ~min:"3.7.0";
      package ~min:"2.3.0" ~sublibs:["mirage"] "arp";
      package ~min:"3.0.0" "ethernet";
      package "shared-memory-ring" ~min:"3.0.0";
      package ~min:"2.1.2" "netchannel";
      package "mirage-net-xen";
      package "ipaddr" ~min:"5.2.0";
      package "mirage-qubes" ~min:"0.9.1";
      package ~min:"3.0.1" "mirage-nat";
      package "mirage-logs";
      package "mirage-xen" ~min:"8.0.0";
      package ~min:"6.4.0" "dns-client";
      package "pf-qubes";
    ]
    "Unikernel.Main" (random @-> mclock @-> time @-> job)

let () =
  register "qubes-firewall" [main $ default_random $ default_monotonic_clock $ default_time]
