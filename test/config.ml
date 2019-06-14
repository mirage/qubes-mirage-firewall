open Mirage

let packages = [
  package "ethernet";
  package "arp";
  package "arp-mirage";
  package "ipaddr";
  package "tcpip" ~sublibs:["ipv4"; "udp"; "tcp"];
  package "mirage-qubes";
]

let client =
  foreign
    "Unikernel.Client" @@ random @-> time @-> mclock @-> console @-> network @-> ethernet @-> arpv4 @-> ipv4 @-> udpv4 @-> tcpv4 @-> qubesdb @-> job

let db = default_qubesdb
let network = default_network
let ethif = etif default_network
let arp = arp ethif
let ipv4 = ipv4_qubes db ethif arp
let udp = direct_udp ipv4
let tcp = direct_tcp ipv4

let () =
  let job =  [ client $ default_random $ default_time $ default_monotonic_clock $ default_console $ network $ ethif $ arp $ ipv4 $ udp $ tcp $ db ] in
  register "http-fetch" job
