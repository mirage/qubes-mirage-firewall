(* mirage >= 4.9.0 & < 4.11.0 *)
(* Copyright (C) 2017, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Configuration for the "mirage" tool. *)

open Mirage

let main =
  main
    ~packages:
      [
        package "vchan" ~min:"4.0.2";
        package "cstruct";
        package "tcpip" ~min:"3.7.0";
        package ~min:"2.3.0" ~sublibs:[ "mirage" ] "arp";
        package ~min:"3.0.0" "ethernet";
        package "shared-memory-ring" ~min:"3.0.0";
        package "mirage-net-xen" ~min:"2.1.4";
        package "ipaddr" ~min:"5.2.0";
        package "mirage-qubes" ~min:"0.9.1";
        package ~min:"3.0.1" "mirage-nat";
        package "mirage-logs";
        package "mirage-xen" ~min:"8.0.0";
        package ~min:"6.4.0" "dns-client";
        package "pf-qubes";
      ]
    "Unikernel" job

let () = register "qubes-firewall" [ main ]
