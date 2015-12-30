(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Perform NAT on the interface to our NetVM.
    Based on https://github.com/yomimono/simple-nat *)

let src = Logs.Src.create "nat-rules" ~doc:"Firewall NAT rules"
module Log = (val Logs.src_log src : Logs.LOG)

let random_user_port () =
  1024 + Random.int (0xffff - 1024)

(* Add a NAT rule for the endpoints in this frame, via a random port on [ip]. *)
let allow_nat_traffic table frame (ip : Ipaddr.t) =
  let rec stubborn_insert port =
    (* TODO: in the unlikely event that no port is available, this
       function will never terminate (this is really a tcpip todo) *)
    let open Nat_rewrite in
    match make_nat_entry table frame ip port with
    | Ok t ->
        Log.info "added NAT entry: %s:%d -> firewall:%d -> %s:%d"
          (fun f ->
            match Nat_rewrite.layers frame with
            | None -> assert false
            | Some (_eth, ip, transport) ->
            let src, dst = Nat_rewrite.addresses_of_ip ip in
            let sport, dport = Nat_rewrite.ports_of_transport transport in
            f (Ipaddr.to_string src) sport port (Ipaddr.to_string dst) dport
          );
        Some t
    | Unparseable -> None
    | Overlap -> stubborn_insert (random_user_port ())
  in
  (* TODO: connection tracking logic *)
  stubborn_insert (random_user_port ())

(** Perform translation on [frame] and return translated packet.
    Update NAT table for new outbound connections. *)
let nat translation_ip nat_table direction frame =
  let rec retry () =
    (* typical NAT logic: traffic from the internal "trusted" interface gets
       new mappings by default; traffic from other interfaces gets dropped if
       no mapping exists (which it doesn't, since we already checked) *)
    let open Nat_rewrite in
    match direction, Nat_rewrite.translate nat_table direction frame with
    | _, Some f -> Some f
    | Destination, None -> None (* nothing in the table, drop it *)
    | Source, None ->
      (* mutate nat_table to include entries for the frame *)
      match allow_nat_traffic nat_table frame translation_ip with
      | Some _t ->
          (* try rewriting again; we should now have an entry for this packet *)
          retry ()
      | None ->
          (* this frame is hopeless! *)
          None in
  retry ()
