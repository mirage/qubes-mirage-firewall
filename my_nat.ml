(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix

let src = Logs.Src.create "my-nat" ~doc:"NAT shim"
module Log = (val Logs.src_log src : Logs.LOG)

type action = [
  | `NAT
  | `Redirect of Mirage_nat.endpoint
]

type ports = {
  nat_tcp : Ports.t ref;
  nat_udp : Ports.t ref;
  nat_icmp : Ports.t ref;
  dns_udp : Ports.t ref;
}

let empty_ports () =
  let nat_tcp = ref Ports.empty in
  let nat_udp = ref Ports.empty in
  let nat_icmp = ref Ports.empty in
  let dns_udp = ref Ports.empty in
  { nat_tcp ; nat_udp ; nat_icmp ; dns_udp }

module Nat = Mirage_nat_lru

type t = {
  table : Nat.t;
}

let create ~max_entries =
  let tcp_size = 7 * max_entries / 8 in
  let udp_size = max_entries - tcp_size in
  let table = Nat.empty ~tcp_size ~udp_size ~icmp_size:100 in
  { table }

let translate t packet =
  match Nat.translate t.table packet with
  | Error (`Untranslated | `TTL_exceeded as e) ->
    Log.debug (fun f -> f "Failed to NAT %a: %a"
                  Nat_packet.pp packet
                  Mirage_nat.pp_error e
              );
    None
  | Ok packet -> Some packet

let pick_free_port ~nat_ports ~dns_ports =
  Ports.pick_free_port ~consult:dns_ports nat_ports

(* just clears the nat ports, dns ports stay as is *)
let reset t ports =
  ports.nat_tcp := Ports.empty;
  ports.nat_udp := Ports.empty;
  ports.nat_icmp := Ports.empty;
  Nat.reset t.table

let remove_connections t ports ip =
  let freed_ports = Nat.remove_connections t.table ip in
  ports.nat_tcp := Ports.diff !(ports.nat_tcp) (Ports.of_list freed_ports.Mirage_nat.tcp);
  ports.nat_udp := Ports.diff !(ports.nat_udp) (Ports.of_list freed_ports.Mirage_nat.udp);
  ports.nat_icmp := Ports.diff !(ports.nat_icmp) (Ports.of_list freed_ports.Mirage_nat.icmp)

let add_nat_rule_and_translate t ports ~xl_host action packet =
  let rec aux ~retries =
    let nat_ports, dns_ports =
      match packet with
      | `IPv4 (_, `TCP _) -> ports.nat_tcp, ref Ports.empty
      | `IPv4 (_, `UDP _) -> ports.nat_udp, ports.dns_udp
      | `IPv4 (_, `ICMP _) -> ports.nat_icmp, ref Ports.empty
    in
    let xl_port = pick_free_port ~nat_ports ~dns_ports in
    match Nat.add t.table packet xl_host (fun () -> xl_port) action with
    | Error `Overlap when retries < 0 -> Error "Too many retries"
    | Error `Overlap ->
      if retries = 0 then (
        Log.warn (fun f -> f "Failed to find a free port; resetting NAT table");
        reset t ports;
        aux ~retries:(retries - 1)
      ) else (
        aux ~retries:(retries - 1)
      )
    | Error `Cannot_NAT ->
      Error "Cannot NAT this packet"
    | Ok () ->
      Log.debug (fun f -> f "Updated NAT table: %a" Nat.pp_summary t.table);
      Option.to_result ~none:"No NAT entry, even after adding one!"
        (translate t packet)
  in
  aux ~retries:100
