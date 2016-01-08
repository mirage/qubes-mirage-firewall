(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

let buf = Buffer.create 200
let log_fmt = Format.formatter_of_buffer buf

let string_of_level =
  let open Logs in function
  | App -> "APP"
  | Error -> "ERR"
  | Warning -> "WRN"
  | Info -> "INF"
  | Debug -> "DBG"

let fmt_timestamp tm =
  let open Clock in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d.%02d"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

module Make (C : V1.CLOCK) = struct
  let init_logging () =
    let report src level ~over k msgf =
      let now = C.time () |> Clock.gmtime |> fmt_timestamp in
      let lvl = string_of_level level in
      let k _ =
        let msg = Buffer.contents buf in
        Buffer.clear buf;
        output_string stderr (msg ^ "\n");
        flush stderr;
        MProf.Trace.label msg;
        over ();
        k () in
      msgf @@ fun ?header:_ ?tags:_ fmt ->
      Format.kfprintf k log_fmt ("%s: %s [%s] " ^^ fmt) now lvl (Logs.Src.name src) in
    Logs.set_reporter { Logs.report }
end
