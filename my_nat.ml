(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix

let src = Logs.Src.create "my-nat" ~doc:"NAT shim"
module Log = (val Logs.src_log src : Logs.LOG)

type action = [
  | `Rewrite
  | `Redirect of Ipaddr.t * int
]

(* To avoid needing to allocate a new NAT table when we've run out of
   memory, pre-allocate the new one ahead of time. *)
type 'a with_standby = {
  mutable current :'a;
  mutable next : 'a;
}

type t = Nat : (module Mirage_nat.S with type t = 't and type config = 'c) * 'c * 't with_standby -> t

let create (type c t) (nat:(module Mirage_nat.S with type config = c and type t = t)) (c:c) =
  let (module Nat : Mirage_nat.S with type config = c and type t = t) = nat in
  Nat.empty c >>= fun current ->
  Nat.empty c >>= fun next ->
  let table = { current; next } in
  Lwt.return (Nat (nat, c, table))

let translate (Nat ((module Nat), _, table)) packet =
  Nat.translate table.current packet >|= function
  | Error `Untranslated -> None
  | Ok packet -> Some packet

let random_user_port () =
  1024 + Random.int (0xffff - 1024)

let reset (Nat ((module Nat), c, table)) =
  table.current <- table.next;
  (* (at this point, the big old NAT table can be GC'd, so allocating
     a new one should be OK) *)
  Nat.empty c >|= fun next ->
  table.next <- next

let add_nat_rule_and_translate ((Nat ((module Nat), c, table)) as t) ~xl_host action packet =
  let apply_action xl_port =
    Lwt.catch (fun () ->
        match action with
        | `Rewrite ->
          Nat.add_nat table.current packet (xl_host, xl_port)
        | `Redirect target ->
          Nat.add_redirect table.current packet (xl_host, xl_port) target
      )
      (function
        | Out_of_memory -> Lwt.return (Error `Out_of_memory)
        | x -> Lwt.fail x
      )
  in
  let reset () =
    table.current <- table.next;
    (* (at this point, the big old NAT table can be GC'd, so allocating
       a new one should be OK) *)
    Nat.empty c >|= fun next ->
    table.next <- next
  in
  let rec aux ~retries =
    let xl_port = random_user_port () in
    apply_action xl_port >>= function
    | Error `Out_of_memory ->
        (* Because hash tables resize in big steps, this can happen even if we have a fair
           chunk of free memory. *)
        Log.warn (fun f -> f "Out_of_memory adding NAT rule. Dropping NAT table...");
        reset () >>= fun () ->
        aux ~retries:(retries - 1)
    | Error `Overlap when retries < 0 -> Lwt.return (Error "Too many retries")
    | Error `Overlap ->
        if retries = 0 then (
          Log.warn (fun f -> f "Failed to find a free port; resetting NAT table");
          reset () >>= fun () ->
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
(*
          Log.debug (fun f ->
              match action with
              | `Rewrite ->
                let (ip, trans) = packet in
                let src, dst = Nat_rewrite.addresses_of_ip ip in
                let sport, dport = Nat_rewrite.ports_of_transport transport in
                f "added NAT entry: %s:%d -> firewall:%d -> %d:%s" (Ipaddr.to_string src) sport xl_port dport (Ipaddr.to_string dst)
              | `Redirect ->
                let (ip, transport) = packet in
                let src, _dst = Nat_rewrite.addresses_of_ip ip in
                let sport, dport = Nat_rewrite.ports_of_transport transport in
                f "added NAT redirect %s:%d -> %d:firewall:%d -> %d:%a"
                  (Ipaddr.to_string src) sport dport xl_port port pp_host host
            );
*)
          Ok packet
  in
  aux ~retries:100
