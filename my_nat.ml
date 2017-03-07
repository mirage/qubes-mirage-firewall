(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix

let src = Logs.Src.create "my-nat" ~doc:"NAT shim"
module Log = (val Logs.src_log src : Logs.LOG)

type action = [
  | `Rewrite
  | `Redirect of Ipaddr.t * int
]

type t = Nat : (module Mirage_nat.S with type t = 't) * 't -> t

let create (type t) (nat:(module Mirage_nat.S with type t = t)) (table:t) =
  let (module Nat : Mirage_nat.S with type t = t) = nat in
  Nat (nat, table)

let translate (Nat ((module Nat), table)) packet =
  Nat.translate table packet >|= function
  | Error `Untranslated -> None
  | Ok packet -> Some packet

let random_user_port () =
  1024 + Random.int (0xffff - 1024)

let reset (Nat ((module Nat), table)) =
  Nat.reset table

let add_nat_rule_and_translate ((Nat ((module Nat), table)) as t) ~xl_host action packet =
  let apply_action xl_port =
    Lwt.catch (fun () ->
        match action with
        | `Rewrite ->
          Nat.add_nat table packet (xl_host, xl_port)
        | `Redirect target ->
          Nat.add_redirect table packet (xl_host, xl_port) target
      )
      (function
        | Out_of_memory -> Lwt.return (Error `Out_of_memory)
        | x -> Lwt.fail x
      )
  in
  let rec aux ~retries =
    let xl_port = random_user_port () in
    apply_action xl_port >>= function
    | Error `Out_of_memory ->
        (* Because hash tables resize in big steps, this can happen even if we have a fair
           chunk of free memory. *)
        Log.warn (fun f -> f "Out_of_memory adding NAT rule. Dropping NAT table...");
        Nat.reset table >>= fun () ->
        aux ~retries:(retries - 1)
    | Error `Overlap when retries < 0 -> Lwt.return (Error "Too many retries")
    | Error `Overlap ->
        if retries = 0 then (
          Log.warn (fun f -> f "Failed to find a free port; resetting NAT table");
          Nat.reset table >>= fun () ->
          aux ~retries:(retries - 1)
        ) else (
          aux ~retries:(retries - 1)
        )
    | Error `Cannot_NAT ->
        Lwt.return (Error "Cannot NAT this packet")
    | Ok () ->
        translate t packet >|= function
        | None -> Error "No NAT entry, even after adding one!"
        | Some packet ->
          Ok packet
  in
  aux ~retries:100
