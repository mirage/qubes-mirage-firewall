(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** General utility functions. *)

module IpMap = struct
  include Map.Make(Ipaddr.V4)
  let find x map =
    try Some (find x map)
    with Not_found -> None
end

module Int = struct
  type t = int
  let compare (a:t) (b:t) = compare a b
end

module IntSet = Set.Make(Int)
module IntMap = Map.Make(Int)

(** An Ethernet interface. *)
class type interface = object
  method my_mac : Macaddr.t
  method writev : Mirage_protocols.Ethernet.proto -> (Cstruct.t -> int) -> unit Lwt.t
  method my_ip : Ipaddr.V4.t
  method other_ip : Ipaddr.V4.t
end

(** An Ethernet interface connected to a clientVM. *)
class type client_link = object
  inherit interface
  method other_mac : Macaddr.t
  method log_header : string  (* For log messages *)
  method get_rules: Pf_qubes.Parse_qubes.rule list
  method set_rules: string Qubes.DB.KeyMap.t -> unit
end

(** An Ethernet header from [src]'s MAC address to [dst]'s with an IPv4 payload. *)
let eth_header ethertype ~src ~dst =
  Ethernet_packet.Marshal.make_cstruct { Ethernet_packet.source = src; destination = dst; ethertype }

let error fmt =
  let err s = Failure s in
  Printf.ksprintf err fmt

let or_raise msg pp = function
  | Ok x -> x
  | Error e -> failwith (Fmt.strf "%s: %a" msg pp e)
