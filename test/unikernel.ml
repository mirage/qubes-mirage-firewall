open Lwt.Infix
open Mirage_types_lwt
open Printf
(* http://erratique.ch/software/logs *)
(* https://github.com/mirage/mirage-logs *)
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
      ICMP
 * - specialtarget:
    x None (UDP fetch test, TCP connect denied test)
      DNS
 * - destination:
    x Any (TCP connect denied test)
    x Some host (UDP fetch test)
 * - destination ports:
    x empty list (TCP connect denied test)
    x list with one item, same port in pair (UDP fetch test)
      list with >1 items, different ports in pair
 * - icmp type:
    x None (TCP connect denied, UDP fetch test)
      query type
      error type
 * - number (ordering over rules, to resolve conflicts by precedence)
      no overlap between rules, i.e. ordering unimportant
      error case: multiple rules with same number?
    x conflicting rules (specific accept rules with low numbers, drop all with high number)
*)

(* Point-to-point links out of a netvm always have this IP TODO clarify with Marek *)
let netvm = "10.137.0.5"
let uri = Uri.of_string @@ "http://" ^ netvm ^ ":8082"

module Client (T: TIME) (C: CONSOLE) (STACK: Mirage_stack_lwt.V4) (RES: Resolver_lwt.S) (CON: Conduit_mirage.S) = struct

  exception Check_error of string
  let check_err fmt = Format.ksprintf (fun err -> raise (Check_error err)) fmt

  let collect_exception f =
    Lwt.try_bind f (fun _ -> Lwt.return None) (fun e -> Lwt.return (Some e))

  let check_raises msg exn f =
    collect_exception f >>= function
    | None ->
      check_err "Fail %s: expecting %s, got nothing." msg (Printexc.to_string exn)
    | Some e when e <> exn ->
      check_err "Fail %s: expecting %s, got %s."
      msg (Printexc.to_string exn) (Printexc.to_string e)
    | Some e ->
      Format.printf "Exception as expected %s" msg;
      Lwt.return_unit

  let tcp_connect port stack =
    Log.info (fun f -> f "Entering tcp connect test: %s:%d"
                 netvm port);
    let ip = Ipaddr.V4.of_string_exn netvm in
    STACK.TCPV4.create_connection (STACK.tcpv4 stack) (ip, port) >>= function
    | Ok flow ->
      Log.info (fun f -> f "TCP test on port %d passed :)" port);
      STACK.TCPV4.close flow
    | Error e -> Log.err (fun f -> f "TCP test failed: Connection failed :(");
      Lwt.return_unit

  let tcp_connect_denied stack =
    let ip = Ipaddr.V4.of_string_exn netvm in
    let port = 80 in
    let connect = (STACK.TCPV4.create_connection (STACK.tcpv4 stack) (ip, port) >>= function
    | Ok flow ->
      Log.err (fun f -> f "TCP connect denied test failed: Connection should be denied, but was not. :(");
      STACK.TCPV4.close flow
    | Error e -> Log.info (fun f -> f "TCP connect denied test passed :)");
      Lwt.return_unit)
    in
    let timeout = (
      T.sleep_ns 1_000_000_000L >>= fun () ->
      Log.info (fun f -> f "TCP connect denied test passed :)");
      Lwt.return_unit)
    in
    Lwt.pick [ connect ; timeout ]

  let udp_fetch ~src_port ~echo_server_port (stack : STACK.t) =
    Log.info (fun f -> f "Entering udp fetch test: %d -> %s:%d"
                 src_port netvm echo_server_port);
    let resp_correct = ref false in
    let echo_server = Ipaddr.V4.of_string_exn netvm in
    let content = Cstruct.of_string "important data" in
    STACK.listen_udpv4 stack ~port:src_port (fun ~src ~dst:_ ~src_port buf ->
        Log.debug (fun f -> f "listen_udpv4 function invoked for packet: %a" Cstruct.hexdump_pp buf);
        if ((0 = Ipaddr.V4.compare echo_server src) && src_port = echo_server_port) then
          (* TODO: how do we stop the listener from here? *)
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
            Log.debug (fun f -> f "packet is not from the echo server or has the wrong source port");
            Lwt.return_unit
          end
      );
    Lwt.async (fun () -> STACK.listen stack);
    STACK.UDPV4.write ~src_port ~dst:echo_server ~dst_port:echo_server_port (STACK.udpv4 stack) content >>= function
    | Ok () -> (* .. listener: test with accept rule, if we get reply we're good *)
      T.sleep_ns 2_000_000_000L >>= fun () ->
      if !resp_correct then Lwt.return_unit else begin
        Log.err (fun f -> f "UDP fetch test: failed. :( correct response not received");
        Lwt.return_unit
      end
    | Error _ ->
      Log.err (fun f -> f "UDP fetch test: failed: :( couldn't write the packet");
      Lwt.return_unit

  let start _time c stack res (ctx:CON.t) =
    udp_fetch ~src_port:9090 ~echo_server_port:1235 stack >>= fun () ->
    udp_fetch ~src_port:9091 ~echo_server_port:6668 stack >>= fun () ->
    tcp_connect 53 stack >>= fun () ->
    tcp_connect 8082 stack >>= fun () ->
    tcp_connect_denied stack

end
