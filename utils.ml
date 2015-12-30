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
  method other_ip : Ipaddr.V4.t
end

(** An Ethernet interface connected to a clientVM. *)
class type client_link = object
  inherit interface
  method other_mac : Macaddr.t
end

(** An Ethernet header from [src]'s MAC address to [dst]'s with an IPv4 payload. *)
let eth_header_ipv4 ~src ~dst =
  let open Wire_structs in
  let frame = Cstruct.create sizeof_ethernet in
  frame |> set_ethernet_src (Macaddr.to_bytes src) 0;
  frame |> set_ethernet_dst (Macaddr.to_bytes dst) 0;
  set_ethernet_ethertype frame (ethertype_to_int IPv4);
  frame

(** Recalculate checksums after modifying packets.
    Note that frames often arrive with invalid checksums due to checksum offload.
    For now, we always calculate valid checksums for out-bound frames. *)
let fixup_checksums frame =
  match Nat_rewrite.layers frame with
  | None -> raise (Invalid_argument "NAT transformation rendered packet unparseable")
  | Some (ether, ip, tx) ->
    let (just_headers, higherlevel_data) =
      Nat_rewrite.recalculate_transport_checksum (ether, ip, tx)
    in
    [just_headers; higherlevel_data]

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

let or_fail msg = function
  | `Ok x -> return x
  | `Error _ -> fail (Failure msg)
