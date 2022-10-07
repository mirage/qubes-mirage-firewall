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
  mutable udp_dns : int list;
}

let create ~max_entries =
  let tcp_size = 7 * max_entries / 8 in
  let udp_size = max_entries - tcp_size in
  let table = Nat.empty ~tcp_size ~udp_size ~icmp_size:100 in
  { table ; udp_dns = [] }

let pick_free_port t proto =
  let rec go () =
    let p = 1024 + Random.int (0xffff - 1024) in
    match proto with
    | `Udp when List.mem p t.udp_dns -> go ()
    | _ -> p
  in
  go ()

let free_udp_port t ~src ~dst ~dst_port =
  let rec go () =
    let src_port = pick_free_port t `Udp in
    if Nat.is_port_free t.table `Udp ~src ~dst ~src_port ~dst_port then begin
      t.udp_dns <- src_port :: t.udp_dns;
      src_port
    end else
      go ()
  in
  go ()

let translate t packet =
  match Nat.translate t.table packet with
  | Error (`Untranslated | `TTL_exceeded as e) ->
    Log.debug (fun f -> f "Failed to NAT %a: %a"
                  Nat_packet.pp packet
                  Mirage_nat.pp_error e
              );
    None
  | Ok packet -> Some packet

let remove_connections t ip =
  ignore (Nat.remove_connections t.table ip)

let add_nat_rule_and_translate t ~xl_host action packet =
  let proto = match packet with
    | `IPv4 (_, `TCP _) -> `Tcp
    | `IPv4 (_, `UDP _) -> `Udp
    | `IPv4 (_, `ICMP _) -> `Icmp
  in
  match Nat.add t.table packet xl_host (fun () -> pick_free_port t proto) action with
  | Error `Overlap -> Error "Too many retries"
  | Error `Cannot_NAT -> Error "Cannot NAT this packet"
  | Ok () ->
    Log.debug (fun f -> f "Updated NAT table: %a" Nat.pp_summary t.table);
    Option.to_result ~none:"No NAT entry, even after adding one!"
      (translate t packet)
