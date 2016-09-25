(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Put your firewall rules here. *)

open Packet

(* OCaml normally warns if you don't match all fields, but that's OK here. *)
[@@@ocaml.warning "-9"]

(** {2 Actions}

  The possible actions are:

    - [`Accept] : Send the packet to its destination.

    - [`NAT] : Rewrite the packet's source field so packet appears to
      have come from the firewall, via an unused port.
      Also, add NAT rules so related packets will be translated accordingly.

    - [`NAT_to (host, port)] :
      As for [`NAT], but also rewrite the packet's destination fields so it
      will be sent to [host:port].

    - [`Drop reason] drop the packet and log the reason.
*)

(** Decide what to do with a packet from a client VM.
    Note: If the packet matched an existing NAT rule then this isn't called. *)
let from_client = function
  | { dst = (`External _ | `NetVM) } -> `NAT
  | { dst = `Client_gateway; proto = `UDP { dport = 53 } } -> `NAT_to (`NetVM, 53)
  | { dst = (`Client_gateway | `Firewall_uplink) } -> `Drop "packet addressed to firewall itself"
  | { dst = `Client _ } -> `Drop "prevent communication between client VMs"

(** Decide what to do with a packet received from the outside world.
    Note: If the packet matched an existing NAT rule then this isn't called. *)
let from_netvm = function
  | _ -> `Drop "drop by default"
