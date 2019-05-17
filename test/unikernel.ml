open Lwt.Infix
open Mirage_types_lwt
open Printf

let red fmt    = sprintf ("\027[31m"^^fmt^^"\027[m")
let green fmt  = sprintf ("\027[32m"^^fmt^^"\027[m")
let yellow fmt = sprintf ("\027[33m"^^fmt^^"\027[m")
let blue fmt   = sprintf ("\027[36m"^^fmt^^"\027[m")

(* Point-to-point links out of a netvm always have this IP TODO clarify with Marek *) 
let uri = Uri.of_string "http://10.137.0.5:8082"

module Client (T: TIME) (C: CONSOLE) (RES: Resolver_lwt.S) (CON: Conduit_mirage.S) = struct

  let http_fetch c resolver ctx =
    C.log c (yellow "Fetching %s with Cohttp:" (Uri.to_string uri)) >>= fun () ->
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
    http_fetch c res ctx 

end
