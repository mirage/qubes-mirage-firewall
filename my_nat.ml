(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix

let src = Logs.Src.create "my-nat" ~doc:"NAT shim"
module Log = (val Logs.src_log src : Logs.LOG)

type action = [
  | `NAT
  | `Redirect of Mirage_nat.endpoint
]

module Nat = Mirage_nat_lru

type t = {
  table : Nat.t;
  get_time : unit -> Mirage_nat.time;
}

let create ~get_time ~max_entries =
  let tcp_size = 7 * max_entries / 8 in
  let udp_size = max_entries - tcp_size in
  Nat.empty ~tcp_size ~udp_size ~icmp_size:100 >|= fun table ->
  { get_time; table }

let translate t packet =
  Nat.translate t.table packet >|= function
  | Error (`Untranslated | `TTL_exceeded as e) ->
    Log.debug (fun f -> f "Failed to NAT %a: %a"
                  Nat_packet.pp packet
                  Mirage_nat.pp_error e
              );
    None
  | Ok packet -> Some packet

let random_user_port () =
  1024 + Random.int (0xffff - 1024)

let reset t =
  Nat.reset t.table

let add_nat_rule_and_translate t ~xl_host action packet =
  let now = t.get_time () in
  let apply_action xl_port =
    Lwt.catch (fun () ->
        Nat.add t.table ~now packet (xl_host, xl_port) action
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
      Nat.reset t.table >>= fun () ->
      aux ~retries:(retries - 1)
    | Error `Overlap when retries < 0 -> Lwt.return (Error "Too many retries")
    | Error `Overlap ->
      if retries = 0 then (
        Log.warn (fun f -> f "Failed to find a free port; resetting NAT table");
        Nat.reset t.table >>= fun () ->
        aux ~retries:(retries - 1)
      ) else (
        aux ~retries:(retries - 1)
      )
    | Error `Cannot_NAT ->
      Lwt.return (Error "Cannot NAT this packet")
    | Ok () ->
      Log.debug (fun f -> f "Updated NAT table: %a" Nat.pp_summary t.table);
      translate t packet >|= function
      | None -> Error "No NAT entry, even after adding one!"
      | Some packet ->
        Ok packet
  in
  aux ~retries:100
