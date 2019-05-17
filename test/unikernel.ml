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

module Client (T: TIME) (C: CONSOLE) (RES: Resolver_lwt.S) (CON: Conduit_mirage.S) = struct

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

  let start _time c res (ctx:CON.t) =
    C.log c (sprintf "Resolving using DNS server 8.8.8.8 (hardcoded)") >>= fun () ->
    (* wait a sec so we catch the output if it's fast *)
    OS.Time.sleep_ns (Duration.of_sec 1) >>= fun () ->
    check_raises "fetch webpage, shold be denied" (Failure "TCP connection failed: connection attempt timed out") @@ http_fetch c res ctx 

end
