open Lwt.Infix
open Mirage_types_lwt
open Printf
(* http://erratique.ch/software/logs *)
(* https://github.com/mirage/mirage-logs *)
let src = Logs.Src.create "firewalltest" ~doc:"Firewalltest"
module Log = (val Logs.src_log src : Logs.LOG)

(* TODO
 * things we can have in rule
 * - action: accept, drop
 * - proto: None, TCP, UDP, ICMP
 * - specialtarget: None, DNS
 * - destination: Any, Some host
 * - destination ports: possibly empty list of ranges
 * - number (ordering over rules, to resolve conflicts by precedence)
 *)
(* Point-to-point links out of a netvm always have this IP TODO clarify with Marek *)
let uri = Uri.of_string "http://10.137.0.5:8082"

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

  let http_fetch c resolver ctx =
    check_raises "HTTP fetch test: " (Failure "TCP connection failed: connection attempt timed out") @@ fun () -> (
    let ctx = Cohttp_mirage.Client.ctx resolver ctx in
    Cohttp_mirage.Client.get ~ctx uri >>= fun (response, body) ->
    Cohttp_lwt.Body.to_string body >>= fun body ->
    Log.err (fun f -> f "HTTP fetch test: failed :( Got something where we wanted to deny all.");
    Lwt.return_unit)

  let udp_fetch (stack : STACK.t) =
    Log.info (fun f -> f "Entering udp fetch test!!!");
    let src_port = 9090 in
    let echo_port = 1235 in
    let resp_received = ref false in
    let echo_server = Ipaddr.V4.of_string_exn "10.137.0.5" in
    let content = Cstruct.of_string "important data" in
    STACK.listen_udpv4 stack ~port:src_port (fun ~src ~dst:_ ~src_port buf ->
        Log.debug (fun f -> f "listen_udpv4 function invoked for packet: %a" Cstruct.hexdump_pp buf);
        if ((0 = Ipaddr.V4.compare echo_server src) && src_port = echo_port) then
          (* TODO: how do we stop the listener from here? *)
          match Cstruct.equal buf content with
          | true -> (* yay *)
            Log.info (fun f -> f "UDP fetch test: passed :)");
            resp_received := true;
            Lwt.return_unit
          | false -> (* oh no *)
            Log.err (fun f -> f "UDP fetch test: failed. :( Packet corrupted; expected %a but got %a" Cstruct.hexdump_pp content Cstruct.hexdump_pp buf);
            Lwt.return_unit
        else
          begin
            (* disregard this packet *)
            Log.debug (fun f -> f "packet is not from the echo server or has the wrong source port");
            Lwt.return_unit
          end
      );
    Lwt.async (fun () -> STACK.listen stack);
    STACK.UDPV4.write ~src_port ~dst:echo_server ~dst_port:echo_port (STACK.udpv4 stack) content >>= function
    | Ok () -> (* .. listener: test with accept rule, if we get reply we're good *)
      T.sleep_ns 2_000_000_000L >>= fun () ->
      if !resp_received then Lwt.return_unit else begin
        Log.err (fun f -> f "UDP fetch test: failed. :( no response was received");
        Lwt.return_unit
      end
    | Error _ ->
      Log.err (fun f -> f "UDP fetch test: failed: :( couldn't write the packet");
      Lwt.return_unit

  let start _time c stack res (ctx:CON.t) =
    udp_fetch stack (*>>= fun () ->
    http_fetch c res ctx *)

end
