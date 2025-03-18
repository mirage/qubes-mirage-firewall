(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

let src = Logs.Src.create "my-nat" ~doc:"NAT shim"

module Log = (val Logs.src_log src : Logs.LOG)

type action = [ `NAT | `Redirect of Mirage_nat.endpoint ]

module Nat = Mirage_nat_lru

module S = Set.Make (struct
  type t = int

  let compare (a : int) (b : int) = compare a b
end)

type t = { table : Nat.t; mutable udp_dns : S.t; last_resort_port : int }

let pick_port () = 1024 + Random.int (0xffff - 1024)

let create ~max_entries =
  let tcp_size = 7 * max_entries / 8 in
  let udp_size = max_entries - tcp_size in
  let table = Nat.empty ~tcp_size ~udp_size ~icmp_size:100 in
  let last_resort_port = pick_port () in
  { table; udp_dns = S.empty; last_resort_port }

let pick_free_port t proto =
  let rec go retries =
    if retries = 0 then None
    else
      let p = 1024 + Random.int (0xffff - 1024) in
      match proto with
      | `Udp when S.mem p t.udp_dns || p = t.last_resort_port -> go (retries - 1)
      | _ -> Some p
  in
  go 10

let free_udp_port t ~src ~dst ~dst_port =
  let rec go retries =
    if retries = 0 then (t.last_resort_port, Fun.id)
    else
      let src_port =
        Option.value ~default:t.last_resort_port (pick_free_port t `Udp)
      in
      if Nat.is_port_free t.table `Udp ~src ~dst ~src_port ~dst_port then
        let remove =
          if src_port <> t.last_resort_port then (
            t.udp_dns <- S.add src_port t.udp_dns;
            fun () -> t.udp_dns <- S.remove src_port t.udp_dns)
          else Fun.id
        in
        (src_port, remove)
      else go (retries - 1)
  in
  go 10

let dns_port t port = S.mem port t.udp_dns || port = t.last_resort_port

let translate t packet =
  match Nat.translate t.table packet with
  | Error ((`Untranslated | `TTL_exceeded) as e) ->
      Log.debug (fun f ->
          f "Failed to NAT %a: %a" Nat_packet.pp packet Mirage_nat.pp_error e);
      None
  | Ok packet -> Some packet

let remove_connections t ip = ignore (Nat.remove_connections t.table ip)

let add_nat_rule_and_translate t ~xl_host action packet =
  let proto =
    match packet with
    | `IPv4 (_, `TCP _) -> `Tcp
    | `IPv4 (_, `UDP _) -> `Udp
    | `IPv4 (_, `ICMP _) -> `Icmp
  in
  match
    Nat.add t.table packet xl_host (fun () -> pick_free_port t proto) action
  with
  | Error `Overlap -> Error "Too many retries"
  | Error `Cannot_NAT -> Error "Cannot NAT this packet"
  | Ok () ->
      Log.debug (fun f -> f "Updated NAT table: %a" Nat.pp_summary t.table);
      Option.to_result ~none:"No NAT entry, even after adding one!"
        (translate t packet)
