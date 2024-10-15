open Lwt.Infix
(* https://www.qubes-os.org/doc/vm-interface/#firewall-rules-in-4x *)
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
    x range has different ports in pair
 * - icmp type:
    x None (TCP connect denied, UDP fetch test)
    x query type (ping test)
      error type
    x - errors related to allowed traffic (does it have a host waiting for it?)
    x - directly allowed outbound icmp errors (e.g. for forwarding)
 * - number (ordering over rules, to resolve conflicts by precedence)
      no overlap between rules, i.e. ordering unimportant
      error case: multiple rules with same number?
    x conflicting rules (specific accept rules with low numbers, drop all with high number)
*)

(* Point-to-point links out of a netvm always have this IP TODO clarify with Marek *)
let netvm = "10.137.0.5"
(* default "nameserver"s, which netvm redirects to whatever its real nameservers are *)
let nameserver_1, nameserver_2 = "10.139.1.1", "10.139.1.2"

module Client (R: Mirage_crypto_rng_mirage.S) (Time: Mirage_time.S) (Clock : Mirage_clock.MCLOCK) (NET: Mirage_net.S) (DB : Qubes.S.DB) = struct
  module E = Ethernet.Make(NET)
  module A = Arp.Make(E)(Time)
  module I = Qubesdb_ipv4.Make(DB)(R)(Clock)(E)(A)
  module Icmp = Icmpv4.Make(I)
  module U = Udp.Make(I)(R)
  module T = Tcp.Flow.Make(I)(Time)(Clock)(R)

  module Alcotest = Alcotest_mirage.Make(Clock)

  module Stack = struct
    (* A Mirage_stack.V4 implementation which diverts DHCP messages to a DHCP
       server. The DHCP server needs to get the entire Ethernet frame, because
       the Ethernet source address is the address to send replies to, its IPv4
       addresses (source, destination) do not matter (since the DHCP client that
       sent this request does not have an IP address yet). ARP cannot be used
       by DHCP, because the client does not have an IP address (and thus no ARP
       replies). *)

    module UDPV4 = U
    module TCPV4 = T
    module IPV4 = I

    type t = {
      net : NET.t ; eth : E.t ; arp : A.t ;
      ip : I.t ; icmp : Icmp.t ; udp : U.t ; tcp : T.t ;
      udp_listeners : (int, U.callback) Hashtbl.t ;
      tcp_listeners : (int, T.listener) Hashtbl.t ;
      mutable icmp_listener : (src:Ipaddr.V4.t -> dst:Ipaddr.V4.t -> Cstruct.t -> unit Lwt.t) option ;
    }

    let ipv4 { ip ; _ } = ip
    let udpv4 { udp ; _ } = udp
    let tcpv4 { tcp ; _ } = tcp
    let icmpv4 { icmp ; _ } = icmp

    let listener h port = Hashtbl.find_opt h port
    let udp_listener h ~dst_port = listener h dst_port

    let listen_udpv4 { udp_listeners ; _ } ~port cb =
      Hashtbl.replace udp_listeners port cb

    let stop_listen_udpv4 { udp_listeners ; _ } ~port =
      Hashtbl.remove udp_listeners port

    let listen_tcpv4 ?keepalive { tcp_listeners ; _ } ~port cb =
      Hashtbl.replace tcp_listeners port { T.process = cb ; T.keepalive }

    let stop_listen_tcpv4 { tcp_listeners ; _ } ~port =
      Hashtbl.remove tcp_listeners port

    let listen_icmp t cb = t.icmp_listener <- cb

    let listen t =
      let ethif_listener =
        E.input
          ~arpv4:(A.input t.arp)
          ~ipv4:(
            I.input
              ~tcp:(T.input t.tcp ~listeners:(listener t.tcp_listeners))
              ~udp:(U.input t.udp ~listeners:(udp_listener t.udp_listeners))
              ~default:(fun ~proto ~src ~dst buf ->
                  match proto with
                  | 1 ->
                     begin match t.icmp_listener with
                     | None -> Icmp.input t.icmp ~src ~dst buf
                     | Some cb -> cb ~src ~dst buf
                     end
                  | _ -> Lwt.return_unit)
              t.ip)
          ~ipv6:(fun _ -> Lwt.return_unit)
          t.eth
      in
      NET.listen t.net ~header_size:Ethernet_wire.sizeof_ethernet ethif_listener
      >>= function
      | Error e ->
        Logs.warn (fun p -> p "%a" NET.pp_error e) ;
        Lwt.return_unit
      | Ok _res -> Lwt.return_unit

    let connect net eth arp ip icmp udp tcp =
      { net ; eth ; arp ; ip ; icmp ; udp ; tcp ;
        udp_listeners = Hashtbl.create 2 ;
        tcp_listeners = Hashtbl.create 2 ;
        icmp_listener = None ;
      }

    let disconnect _ =
      Logs.warn (fun m -> m "ignoring disconnect");
      Lwt.return_unit
  end

  module Dns = Dns_client_mirage.Make(R)(Time)(Clock)(Stack)

  let make_ping_packet payload =
    let echo_request = { Icmpv4_packet.code = 0; (* constant for echo request/reply *)
                         ty = Icmpv4_wire.Echo_request;
                         subheader = Icmpv4_packet.(Id_and_seq (0, 0)); } in
    Icmpv4_packet.Marshal.make_cstruct echo_request ~payload

  let is_ping_reply src server packet =
    0 = Ipaddr.V4.(compare src @@ of_string_exn server) &&
    packet.Icmpv4_packet.code = 0 &&
    packet.Icmpv4_packet.ty = Icmpv4_wire.Echo_reply &&
    packet.Icmpv4_packet.subheader = Icmpv4_packet.(Id_and_seq (0, 0))

  let ping_denied_listener server resp_received stack =
    let icmp_listener ~src ~dst:_ buf =
      (* hopefully this is a reply to an ICMP echo request we sent *)
      Log.info (fun f -> f "ping test: ICMP message received from %a: %a" I.pp_ipaddr src Cstruct.hexdump_pp buf);
      match Icmpv4_packet.Unmarshal.of_cstruct buf with
      | Error e -> Log.err (fun f -> f "couldn't parse ICMP packet: %s" e);
                   Lwt.return_unit
      | Ok (packet, _payload) ->
         Log.info (fun f -> f "ICMP message: %a" Icmpv4_packet.pp packet);
         if is_ping_reply src server packet then resp_received := true;
         Lwt.return_unit
    in
    Stack.listen_icmp stack (Some icmp_listener)

  let ping_expect_failure server stack () =
    let resp_received = ref false in
    Log.info (fun f -> f "Entering ping test: %s" server);
    ping_denied_listener server resp_received stack;
    Icmp.write (Stack.icmpv4 stack) ~dst:(Ipaddr.V4.of_string_exn server) (make_ping_packet (Cstruct.of_string "hi")) >>= function
    | Error e -> Log.err (fun f -> f "ping test: error sending ping: %a" Icmp.pp_error e); Lwt.return_unit
    | Ok () ->
      Log.info (fun f -> f "ping test: sent ping to %s" server);
      Time.sleep_ns 2_000_000_000L >>= fun () ->
      (if !resp_received then
        Log.err (fun f -> f "ping test failed: server %s got a response, block expected :(" server)
      else
        Log.err (fun f -> f "ping test passed: successfully blocked :)")
      );
      Stack.listen_icmp stack None;
      Lwt.return_unit

  let icmp_error_type stack () =
    let resp_correct = ref false in
    let echo_server = Ipaddr.V4.of_string_exn netvm in
    let icmp_callback ~src ~dst:_ buf =
      if Ipaddr.V4.compare src echo_server = 0 then begin
          (* TODO: check that packet is error packet *)
          match Icmpv4_packet.Unmarshal.of_cstruct buf with
          | Error e -> Log.err (fun f -> f "Error parsing icmp packet %s" e)
          | Ok (packet, _) ->
             (* TODO don't hardcode the numbers, make a datatype *)
             if packet.Icmpv4_packet.code = 10 (* unreachable, admin prohibited *)
             then resp_correct := true
             else Log.debug (fun f -> f "Unrelated icmp packet %a" Icmpv4_packet.pp packet)
        end;
      Lwt.return_unit
    in
    let content = Cstruct.of_string "important data" in
    Stack.listen_icmp stack (Some icmp_callback);
    U.write ~src_port:1337 ~dst:echo_server ~dst_port:1338 (Stack.udpv4 stack) content >>= function
    | Ok () -> (* .. listener: test with accept rule, if we get reply we're good *)
       Time.sleep_ns 1_000_000_000L >>= fun () ->
       if !resp_correct
       then Log.info (fun m -> m "UDP fetch test to port %d succeeded :)" 1338)
       else Log.err (fun f -> f "UDP fetch test to port %d: failed. :( correct response not received" 1338);
       Stack.listen_icmp stack None;
       Lwt.return_unit
    | Error e ->
       Log.err (fun f -> f "UDP fetch test to port %d failed: :( couldn't write the packet: %a"
                           1338 U.pp_error e);
      Lwt.return_unit

  let tcp_connect msg server port tcp () =
    Log.info (fun f -> f "Entering tcp connect test: %s:%d" server port);
    let ip = Ipaddr.V4.of_string_exn server in
    let msg' = Printf.sprintf "TCP connect test %s to %s:%d" msg server port in
    T.create_connection tcp (ip, port) >>= function
    | Ok flow ->
      Log.info (fun f -> f "%s passed :)" msg');
      T.close flow
    | Error e -> Log.err (fun f -> f "%s failed: Connection failed (%a) :(" msg' T.pp_error e);
      Lwt.return_unit

  let tcp_connect_denied msg server port tcp () =
    let ip = Ipaddr.V4.of_string_exn server in
    let msg' = Printf.sprintf "TCP connect denied test %s to %s:%d" msg server port in
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

  let udp_fetch ~src_port ~echo_server_port stack () =
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
    Stack.listen_udpv4 stack ~port:src_port udp_listener;
    U.write ~src_port ~dst:echo_server ~dst_port:echo_server_port (Stack.udpv4 stack) content >>= function
    | Ok () -> (* .. listener: test with accept rule, if we get reply we're good *)
      Time.sleep_ns 1_000_000_000L >>= fun () ->
      Stack.stop_listen_udpv4 stack ~port:src_port;
      if !resp_correct then Lwt.return_unit else begin
        Log.err (fun f -> f "UDP fetch test to port %d: failed. :( correct response not received" echo_server_port);
        Lwt.return_unit
      end
    | Error e ->
      Log.err (fun f -> f "UDP fetch test to port %d failed: :( couldn't write the packet: %a"
                  echo_server_port U.pp_error e);
      Lwt.return_unit

  let dns_expect_failure ~nameserver ~hostname stack () =
    let lookup = Domain_name.(of_string_exn hostname |> host_exn) in
    let nameserver' = `UDP, (Ipaddr.V4.of_string_exn nameserver, 53) in
    let dns = Dns.create ~nameserver:nameserver' stack in
    Dns.gethostbyname dns lookup >>= function
    | Error (`Msg s) when String.compare s "Truncated UDP response" <> 0 -> Log.debug (fun f -> f "DNS test to %s failed as expected: %s"
                                      nameserver s);
      Log.info (fun f -> f "DNS traffic to %s correctly blocked :)" nameserver);
      Lwt.return_unit
    | Error (`Msg s) ->
       Log.debug (fun f -> f "DNS test to %s failed unexpectedly (truncated response): %s :("
                             nameserver s);
       Lwt.return_unit
    | Ok addr -> Log.err (fun f -> f "DNS test to %s should have been blocked, but looked up %s:%a" nameserver hostname Ipaddr.V4.pp addr);
      Lwt.return_unit

  let dns_then_tcp_denied server stack () =
    let parsed_server = Domain_name.(of_string_exn server |> host_exn) in
    (* ask dns about server *)
    Log.debug (fun f -> f "going to make a dns thing using nameserver %s" nameserver_1);
    let dns = Dns.create ~nameserver:(`UDP, ((Ipaddr.V4.of_string_exn nameserver_1), 53)) stack in
    Log.debug (fun f -> f "OK, going to look up %s now" server);
    Dns.gethostbyname dns parsed_server >>= function
    | Error (`Msg s) -> Log.err (fun f -> f "couldn't look up ip for %s: %s" server s); Lwt.return_unit
    | Ok addr ->
      Log.debug (fun f -> f "looked up ip for %s: %a" server Ipaddr.V4.pp addr);
      Log.err (fun f -> f "Do more stuff here!!!! :(");
      Lwt.return_unit

  let start _random _time _clock network db =
    E.connect network >>= fun ethernet ->
    A.connect ethernet >>= fun arp ->
    I.connect db ethernet arp >>= fun ipv4 ->
    Icmp.connect ipv4 >>= fun icmp ->
    U.connect ipv4 >>= fun udp ->
    T.connect ipv4 >>= fun tcp ->

    let stack = Stack.connect network ethernet arp ipv4 icmp udp tcp  in
    Lwt.async (fun () -> Stack.listen stack);

    (* put this first because tcp_connect_denied tests also generate icmp messages *)
    let general_tests : unit Alcotest.test = ("firewall tests", [
        ("UDP fetch", `Quick,  udp_fetch ~src_port:9090 ~echo_server_port:1235 stack);
        ("Ping expect failure", `Quick, ping_expect_failure "8.8.8.8" stack );
        (* TODO: ping_expect_success to the netvm, for which we have an icmptype rule in update-firewall.sh *)
        ("ICMP error type", `Quick, icmp_error_type stack)
       ] ) in
    Alcotest.run ~and_exit:false "name" [ general_tests ] >>= fun () ->
    let tcp_tests : unit Alcotest.test = ("tcp tests", [
        (* this test fails on 4.0R3
        ("TCP connect", `Quick, tcp_connect "when trying specialtarget" nameserver_1 53 tcp); *)
        ("TCP connect", `Quick, tcp_connect_denied "" netvm 53 tcp);
        ("TCP connect", `Quick, tcp_connect_denied "when trying below range" netvm 6667 tcp);
        ("TCP connect", `Quick, tcp_connect "when trying lower bound in range" netvm 6668 tcp);
        ("TCP connect", `Quick, tcp_connect "when trying upper bound in range" netvm 6670 tcp);
        ("TCP connect", `Quick, tcp_connect_denied "when trying above range" netvm 6671 tcp);
        ("TCP connect", `Quick, tcp_connect_denied "" netvm 8082 tcp);
      ] ) in

    (* replace the udp-related listeners with the right one for tcp *)
    Alcotest.run "name" [ tcp_tests ] >>= fun () ->
    (* use the stack abstraction only after the other tests have run, since it's not friendly with outside use of its modules *)
    let stack_tests = "stack tests", [
        ("DNS expect failure", `Quick, dns_expect_failure ~nameserver:"8.8.8.8" ~hostname:"mirage.io" stack);

        (* the test below won't work on @linse's internet,
         * because the nameserver there doesn't answer on TCP port 53,
         * only UDP port 53.  Dns_mirage_client.ml disregards our request
         * to use UDP and uses TCP anyway, so this request can never work there. *)
        (* If we can figure out a way to have this test unikernel do a UDP lookup with minimal pain,
         * we should re-enable this test. *)
        ("DNS lookup + TCP connect", `Quick, dns_then_tcp_denied "google.com" stack);
      ] in
    Alcotest.run "name" [ stack_tests ]
end
