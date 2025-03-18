open Mirage

let pin = "git+https://github.com/roburio/alcotest.git#mirage"

let packages =
  [
    package "ethernet";
    package "arp";
    package "arp-mirage";
    package "ipaddr";
    package "tcpip" ~sublibs:[ "stack-direct"; "icmpv4"; "ipv4"; "udp"; "tcp" ];
    package "mirage-qubes";
    package "mirage-qubes-ipv4";
    package "dns-client" ~sublibs:[ "mirage" ];
    package ~pin "alcotest";
    package ~pin "alcotest-mirage";
  ]

let client =
  foreign ~packages "Unikernel.Client"
  @@ random @-> time @-> mclock @-> network @-> qubesdb @-> job

let db = default_qubesdb
let network = default_network

let () =
  let job =
    [
      client $ default_random $ default_time $ default_monotonic_clock $ network
      $ db;
    ]
  in
  register "http-fetch" job
