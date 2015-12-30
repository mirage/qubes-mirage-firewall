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
  method writev : Cstruct.t list -> unit Lwt.t
end

(** An Ethernet interface connected to a clientVM. *)
class type client_link = object
  inherit interface
  method client_ip : Ipaddr.V4.t
  method client_mac : Macaddr.t
end

let (===) a b = (Ipaddr.V4.compare a b = 0)

let error fmt =
  let err s = Failure s in
  Printf.ksprintf err fmt

let return = Lwt.return
let fail = Lwt.fail

(* Copy str to the start of buffer and fill the rest with zeros *)
let set_fixed_string buffer str =
  let len = String.length str in
  Cstruct.blit_from_string str 0 buffer 0 len;
  Cstruct.memset (Cstruct.shift buffer len) 0
