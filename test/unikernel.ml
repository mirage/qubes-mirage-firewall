open Lwt.Infix
open Mirage_types_lwt
open Printf

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
      Format.printf "Exception as expected";
      Lwt.return_unit

  let http_fetch c resolver ctx () =
    C.log c (sprintf "Fetching %s with Cohttp:" (Uri.to_string uri)) >>= fun () ->
    let ctx = Cohttp_mirage.Client.ctx resolver ctx in
    Cohttp_mirage.Client.get ~ctx uri >>= fun (response, body) ->
    Cohttp_lwt.Body.to_string body >>= fun body ->
    C.log c (Sexplib.Sexp.to_string_hum (Cohttp.Response.sexp_of_t response)) >>= fun () ->
    C.log c (sprintf "Received body length: %d" (String.length body)) >>= fun () ->
    C.log c "Cohttp fetch done\n------------\n"

  let udp_fetch (stack : STACK.t) =
    let src_port = 9090 in
    let echo_port = 1235 in
    let echo_server = Ipaddr.V4.of_string_exn "10.137.0.5" in
    let content = Cstruct.of_string "important data" in
    STACK.listen_udpv4 stack ~port:src_port (fun ~src ~dst:_ ~src_port buf ->
        if ((0 = Ipaddr.V4.compare echo_server src) && src_port = echo_port) then
          (* TODO: how do we stop the listener from here? *)
          match Cstruct.equal buf content with
          | true -> (* yay *) Lwt.return_unit
          | false -> (* oh no *)
            Logs.err (fun f -> f "UDP test: packet corrupted; expected %a but got %a" Cstruct.hexdump_pp content Cstruct.hexdump_pp buf);
            Lwt.return_unit
        else
          (* disregard this packet *)
          Lwt.return_unit
      );
    Lwt.async (fun () ->
        Lwt.pick [
          T.sleep_ns 1_000_000_000L;
          STACK.listen stack;
        ]
      );
    STACK.UDPV4.write echo_server echo_port (STACK.udpv4 stack) content >>= function
    | Ok () -> (* .. listener: test with accept rule, if we get reply we're good *) Lwt.return_unit
    | Error _ -> Lwt.return_unit
      
  let start _time c stack res (ctx:CON.t) =
    udp_fetch stack >>= fun () ->
    C.log c (sprintf "Resolving using DNS server 8.8.8.8 (hardcoded)") >>= fun () ->
    (* wait a sec so we catch the output if it's fast *)
    T.sleep_ns (Duration.of_sec 1) >>= fun () ->
    check_raises "fetch webpage, shold be denied" (Failure "TCP connection failed: connection attempt timed out") @@ http_fetch c res ctx 

end
