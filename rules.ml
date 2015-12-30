(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Put your firewall rules here. *)

open Packet

(* OCaml normally warns if you don't match all fields, but that's OK here. *)
[@@@ocaml.warning "-9"]

(** Decide what to do with a packet from a client VM.
    Note: If the packet matched an existing NAT rule then this isn't called. *)
let from_client = function
  | { dst = `External } -> `Accept
  | { dst = `Client_gateway; proto = `UDP { dport = 53 } } -> `Redirect_to_netvm 53
  | { dst = (`Client_gateway | `Firewall_uplink) } -> `Drop "packet addressed to firewall itself"
  | { dst = `Client _ } -> `Drop "prevent communication between client VMs"
  | { dst = `Unknown_client } -> `Drop "target client not running"

(** Decide what to do with a packet received from the outside world.
    Note: If the packet matched an existing NAT rule then this isn't called. *)
let from_netvm = function
  | _ -> `Drop "drop by default"
