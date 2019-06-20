open Lwt.Infix
open Mirage_types_lwt

let src = Logs.Src.create "firewall test" ~doc:"Firewalltest"
module Log = (val Logs.src_log src : Logs.LOG)

(* TODO
 * things we can have in rule
 * - action:
    x accept (UDP fetch test)
    x drop (TCP connect denied test)
 * - proto:
    x None (TCP connect denied test)
    x TCP (TCP connect test)
    x UDP (UDP fetch test)
    x ICMP (ping test)
 * - specialtarget:
    x None (UDP fetch test, TCP connect denied test)
    x DNS (TCP connect test, TCP connect denied test)
 * - destination:
    x Any (TCP connect denied test)
    x Some ipv4 host (UDP fetch test)
      Some ipv6 host (we can't do this right now)
      Some hostname (need a bunch of DNS stuff for that)
 * - destination ports:
    x none (TCP connect denied test)
    x range is one port (UDP fetch test)
      range has different ports in pair
 * - icmp type:
    x None (TCP connect denied, UDP fetch test)
    x query type (ping test)
      error type
 * - number (ordering over rules, to resolve conflicts by precedence)
      no overlap between rules, i.e. ordering unimportant
      error case: multiple rules with same number?
    x conflicting rules (specific accept rules with low numbers, drop all with high number)
*)

(* Point-to-point links out of a netvm always have this IP TODO clarify with Marek *)
let netvm = "10.137.0.5"
(* default "nameserver"s, which netvm redirects to whatever its real nameservers are *)
let nameserver_1, nameserver_2 = "10.139.1.1", "10.139.1.2"

module Client (R: RANDOM) (Time: TIME) (Clock : MCLOCK) (C: CONSOLE) (NET: NETWORK) (DB : Qubes.S.DB) = struct
  module E = Ethernet.Make(NET)
  module A = Arp.Make(E)(Time)
  module I = Qubesdb_ipv4.Make(DB)(R)(Clock)(E)(A)
  module Icmp = Icmpv4.Make(I)
  module U = Udp.Make(I)(R)
  module T = Tcp.Flow.Make(I)(Time)(Clock)(R)

  (* Tcp.create_connection needs this listener; it should be running
     when tcp_connect or tcp_connect_denied tests run *)
  let tcp_listen network ethernet arp ipv4 tcp=
    (NET.listen network ~header_size:Ethernet_wire.sizeof_ethernet
      (E.input ~arpv4:(A.input arp)
         ~ipv4:(I.input
                  ~udp:(fun ~src:_ ~dst:_ _contents -> Lwt.return_unit)
                  ~tcp:(T.input tcp ~listeners:(fun _ -> None))
                  ~default:(fun ~proto:_ ~src:_ ~dst:_ _ ->
                      (* TODO: handle ICMP destination unreachable messages here,
                                  possibly with some detailed help text? *)
                      Lwt.return_unit)
                  ipv4
               )
         ~ipv6:(fun _ -> Lwt.return_unit)
         ethernet)) >>= fun _ -> Lwt.return_unit

  let ping_expect_failure server network ethernet arp ipv4 icmp =
    let make_ping payload =
      let echo_request = { Icmpv4_packet.code = 0; (* constant for echo request/reply *)
                           ty = Icmpv4_wire.Echo_request;
                           subheader = Icmpv4_packet.(Id_and_seq (0, 0)); } in
      Icmpv4_packet.Marshal.make_cstruct echo_request ~payload
    in
    let is_reply src server packet =
      0 = Ipaddr.V4.(compare src @@ of_string_exn server) &&
      packet.Icmpv4_packet.code = 0 &&
      packet.Icmpv4_packet.ty = Icmpv4_wire.Echo_reply &&
      packet.Icmpv4_packet.subheader = Icmpv4_packet.(Id_and_seq (0, 0))
    in
    let icmp_protocol = 1 in
    let resp_received = ref false in
    Log.info (fun f -> f "Entering ping test: %s" server);
    let icmp_listen () =
      (NET.listen network ~header_size:Ethernet_wire.sizeof_ethernet
         (E.input ~arpv4:(A.input arp)
            ~ipv4:(I.input
                     ~udp:(fun ~src:_ ~dst:_ _contents -> Lwt.return_unit)
                     ~tcp:(fun ~src:_ ~dst:_ _contents -> Lwt.return_unit)
                     ~default:(fun ~proto ~src ~dst:_ buf ->
                         if proto = icmp_protocol then begin
                           (* hopefully this is a reply to an ICMP echo request we sent *)
                           Log.info (fun f -> f "ping test: ICMP message received from %a: %a" I.pp_ipaddr src Cstruct.hexdump_pp buf);
                           match Icmpv4_packet.Unmarshal.of_cstruct buf with
                           | Error e -> Log.err (fun f -> f "couldn't parse ICMP packet: %s" e);
                             Lwt.return_unit
                           | Ok (packet, _payload) -> Log.info (fun f -> f "ICMP message: %a" Icmpv4_packet.pp packet);
                             if is_reply src server packet then resp_received := true;
                             Lwt.return_unit
                         end else begin
                           Log.info (fun f -> f "ping test: non-ICMP/TCP/UDP message received? %a" Cstruct.hexdump_pp buf);
                           Lwt.return_unit
                         end)
                     ipv4
                  )
            ~ipv6:(fun _ -> Lwt.return_unit)
            ethernet)) >>= fun _ -> Lwt.return_unit
    in
    Lwt.async icmp_listen;
    Icmp.write icmp ~dst:(Ipaddr.V4.of_string_exn server) (make_ping (Cstruct.of_string "hi")) >>= function
    | Error e -> Log.err (fun f -> f "ping test: error sending ping: %a" Icmp.pp_error e); Lwt.return_unit
    | Ok () ->
      Log.info (fun f -> f "ping test: sent ping to %s" server);
      Time.sleep_ns 2_000_000_000L >>= fun () ->
      if !resp_received then begin
        Log.err (fun f -> f "ping test failed: server %s got a response, block expected :(" server);
        Lwt.return_unit
      end else begin
        Log.err (fun f -> f "ping test passed: successfully blocked :)");
        Lwt.return_unit
      end

  let tcp_connect server port tcp =
    Log.info (fun f -> f "Entering tcp connect test: %s:%d"
                 server port);
    let ip = Ipaddr.V4.of_string_exn server in
    T.create_connection tcp (ip, port) >>= function
    | Ok flow ->
      Log.info (fun f -> f "TCP test to %s:%d passed :)" server port);
      T.close flow
    | Error e -> Log.err (fun f -> f "TCP test to %s:%d failed: Connection failed (%a) :(" server port T.pp_error e);
      Lwt.return_unit

  let tcp_connect_denied msg port tcp =
    let ip = Ipaddr.V4.of_string_exn netvm in
    let msg' = Printf.sprintf "TCP connect denied test %s to %s:%d" msg netvm port in
    let connect = (T.create_connection tcp (ip, port) >>= function
    | Ok flow ->
      Log.err (fun f -> f "%s failed: Connection should be denied, but was not. :(" msg');
      T.close flow
    | Error e -> Log.info (fun f -> f "%s passed (error text: %a) :)" msg' T.pp_error e);
      Lwt.return_unit)
    in
    let timeout = (
      Time.sleep_ns 1_000_000_000L >>= fun () ->
      Log.info (fun f -> f "%s passed :)" msg');
      Lwt.return_unit)
    in
    Lwt.pick [ connect ; timeout ]

  let udp_fetch ~src_port ~echo_server_port network ethernet arp ipv4 udp =
    Log.info (fun f -> f "Entering udp fetch test: %d -> %s:%d"
                 src_port netvm echo_server_port);
    let resp_correct = ref false in
    let echo_server = Ipaddr.V4.of_string_exn netvm in
    let content = Cstruct.of_string "important data" in
    let udp_listener : U.callback = (fun ~src ~dst:_ ~src_port buf ->
        Log.debug (fun f -> f "listen_udpv4 function invoked for packet: %a" Cstruct.hexdump_pp buf);
        if ((0 = Ipaddr.V4.compare echo_server src) && src_port = echo_server_port) then
          match Cstruct.equal buf content with
          | true -> (* yay *)
            Log.info (fun f -> f "UDP fetch test to port %d: passed :)" echo_server_port);
            resp_correct := true;
            Lwt.return_unit
          | false -> (* oh no *)
            Log.err (fun f -> f "UDP fetch test to port %d: failed. :( Packet corrupted; expected %a but got %a"
                        echo_server_port Cstruct.hexdump_pp content Cstruct.hexdump_pp buf);
            Lwt.return_unit
        else
          begin
            (* disregard this packet *)
            Log.debug (fun f -> f "packet is not from the echo server or has the wrong source port (%d but we wanted %d)"
                      src_port echo_server_port);
            (* don't cancel the listener, since we want to keep listening *)
            Lwt.return_unit
          end
      )
    in
    let udp_arg : U.ipinput = U.input ~listeners:(fun ~dst_port:_ -> Some udp_listener) udp in
    Lwt.async (fun () ->
    NET.listen network ~header_size:Ethernet_wire.sizeof_ethernet
                  (E.input ~arpv4:(A.input arp)
                     ~ipv4:(I.input
                              ~udp:udp_arg
                              ~tcp:(fun ~src:_ ~dst:_ _contents -> Lwt.return_unit)
                              ~default:(fun ~proto:_ ~src:_ ~dst:_ _ ->
                                  (* TODO: handle ICMP destination unreachable messages here,
                                              possibly with some detailed help text? *)
                                  Lwt.return_unit)
                              ipv4
                           )
                     ~ipv6:(fun _ -> Lwt.return_unit)
                     ethernet
                  ) >>= fun _ -> Lwt.return_unit
    );
    U.write ~src_port ~dst:echo_server ~dst_port:echo_server_port udp content >>= function
    | Ok () -> (* .. listener: test with accept rule, if we get reply we're good *)
      Time.sleep_ns 1_000_000_000L >>= fun () ->
      if !resp_correct then Lwt.return_unit else begin
        Log.err (fun f -> f "UDP fetch test to port %d: failed. :( correct response not received" echo_server_port);
        Lwt.return_unit
      end
    | Error e ->
      Log.err (fun f -> f "UDP fetch test to port %d failed: :( couldn't write the packet: %a"
                  echo_server_port U.pp_error e);
      Lwt.return_unit

  let start _random _time clock _c network db =
    E.connect network >>= fun ethernet ->
    A.connect ethernet >>= fun arp ->
    I.connect db clock ethernet arp >>= fun ipv4 ->
    Icmp.connect ipv4 >>= fun icmp ->
    U.connect ipv4 >>= fun udp ->
    T.connect ipv4 clock >>= fun tcp ->

    udp_fetch ~src_port:9090 ~echo_server_port:1235 network ethernet arp ipv4 udp >>= fun () ->
    (* put this first because tcp_connect_denied tests also generate icmp messages *)
    ping_expect_failure "8.8.8.8" network ethernet arp ipv4 icmp >>= fun () ->
    (* replace the udp-related listeners with the right one for tcp *)
    Lwt.async (fun () -> tcp_listen network ethernet arp ipv4 tcp);
    tcp_connect nameserver_1 53 tcp >>= fun () ->
    tcp_connect_denied "" 53 tcp >>= fun () ->
    tcp_connect_denied "when trying below range" 6667 tcp >>= fun () ->
    tcp_connect netvm 6668 tcp >>= fun () ->
    tcp_connect netvm 6670 tcp >>= fun () ->
    tcp_connect_denied "when trying above range" 6671 tcp >>= fun () ->
    tcp_connect_denied "" 8082 tcp

end
