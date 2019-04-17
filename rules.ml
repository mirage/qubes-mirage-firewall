(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Put your firewall rules here. *)

open Packet

(* OCaml normally warns if you don't match all fields, but that's OK here. *)
[@@@ocaml.warning "-9"]

(* List your AppVM IP addresses here if you want to match on them in the rules below.
   Any client not listed here will appear as [`Client `Unknown]. *)
let clients = [
  (*
  "10.137.0.12", `Dev;
  "10.137.0.14", `Untrusted;
  *)
]

(* List your external (non-AppVM) IP addresses here if you want to match on them in the rules below.
   Any external machine not listed here will appear as [`External `Unknown]. *)
let externals = [
  (*
  "8.8.8.8", `GoogleDNS;
  *)
]

(** Decide what to do with a packet from a client VM.
    Note: If the packet matched an existing NAT rule then this isn't called. *)
let from_client (info : _ info) : action =
  match info with
  (* Examples (add your own rules here): *)
  (*
  | { src = `Client `Dev; dst = `Client `Untrusted; proto = `TCP { dport = 22 } } -> `Accept
  | { src = `Client _; dst = `Client _; proto = `TCP _; packet }
                                        when not (is_tcp_start packet) -> `Accept
  | { dst = `External `GoogleDNS } -> `Drop "block Google DNS"
  *)
  | { dst = (`External _ | `NetVM) } -> `NAT
  | { dst = `Client_gateway; proto = `UDP { dport = 53 } } -> `NAT_to (`NetVM, 53)
  | { dst = (`Client_gateway | `Firewall_uplink) } -> `Drop "packet addressed to firewall itself"
  | { dst = `Client _ } -> `Drop "prevent communication between client VMs by default"

(** Decide what to do with a packet received from the outside world.
    Note: If the packet matched an existing NAT rule then this isn't called. *)
let from_netvm (info : _ info) : action =
  match info with
  | _ -> `Drop "drop by default"
