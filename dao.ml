(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix
open Utils
open Qubes

type client_vif = {
  domid : int;
  device_id : int;
  client_ip : Ipaddr.V4.t;
}

let client_vifs domid =
  let path = Printf.sprintf "backend/vif/%d" domid in
  OS.Xs.make () >>= fun xs ->
  OS.Xs.immediate xs (fun h ->
    OS.Xs.directory h path >>=
    Lwt_list.map_p (fun device_id ->
      let device_id = int_of_string device_id in
      OS.Xs.read h (Printf.sprintf "%s/%d/ip" path device_id) >|= fun client_ip ->
      let client_ip = Ipaddr.V4.of_string_exn client_ip in
      { domid; device_id; client_ip }
    )
  )

let watch_clients fn =
  OS.Xs.make () >>= fun xs ->
  let backend_vifs = "backend/vif" in
  OS.Xs.wait xs (fun handle ->
    begin Lwt.catch
      (fun () -> OS.Xs.directory handle backend_vifs)
      (function
        | Xs_protocol.Enoent _ -> return []
        | ex -> fail ex)
    end >>= fun items ->
    let items = items |> List.fold_left (fun acc key -> IntSet.add (int_of_string key) acc) IntSet.empty in
    fn items;
    (* Wait for further updates *)
    fail Xs_protocol.Eagain
  )

type network_config = {
  uplink_prefix : Ipaddr.V4.Prefix.t; (* The network connecting us to NetVM *)
  uplink_netvm_ip : Ipaddr.V4.t;      (* The IP address of NetVM (our gateway) *)
  uplink_our_ip : Ipaddr.V4.t;        (* The IP address of our interface to NetVM *)

  clients_prefix : Ipaddr.V4.Prefix.t; (* The network connecting our client VMs to us *)
  clients_our_ip : Ipaddr.V4.t;        (* The IP address of our interface to our client VMs (their gateway) *)
}

let read_network_config qubesDB =
  let get name =
    match DB.read qubesDB name with
    | None -> raise (error "QubesDB key %S not present" name)
    | Some value -> value in
  let uplink_our_ip = get "/qubes-ip" |> Ipaddr.V4.of_string_exn in
  let uplink_netmask = get "/qubes-netmask" |> Ipaddr.V4.of_string_exn in
  let uplink_prefix = Ipaddr.V4.Prefix.of_netmask uplink_netmask uplink_our_ip in
  let uplink_netvm_ip = get "/qubes-gateway" |> Ipaddr.V4.of_string_exn in
  let clients_prefix =
    (* This is oddly named: seems to be the network we provide to our clients *)
    let client_network = get "/qubes-netvm-network" |> Ipaddr.V4.of_string_exn in
    let client_netmask = get "/qubes-netvm-netmask" |> Ipaddr.V4.of_string_exn in
    Ipaddr.V4.Prefix.of_netmask client_netmask client_network in
  let clients_our_ip = get "/qubes-netvm-gateway" |> Ipaddr.V4.of_string_exn in
  { uplink_prefix; uplink_netvm_ip; uplink_our_ip; clients_prefix; clients_our_ip }

let set_iptables_error db = Qubes.DB.write db "/qubes-iptables-error"
