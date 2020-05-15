(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix
open Qubes
open Astring

let src = Logs.Src.create "dao" ~doc:"QubesDB data access"
module Log = (val Logs.src_log src : Logs.LOG)

module ClientVif = struct
  type t = {
    domid : int;
    device_id : int;
  }

  let pp f { domid; device_id } = Fmt.pf f "{domid=%d;device_id=%d}" domid device_id

  let compare = compare
end
module VifMap = struct
  include Map.Make(ClientVif)
  let rec of_list = function
    | [] -> empty
    | (k, v) :: rest -> add k v (of_list rest)
  let find key t =
    try Some (find key t)
    with Not_found -> None
end

let directory ~handle dir =
  OS.Xs.directory handle dir >|= function
  | [""] -> []      (* XenStore client bug *)
  | items -> items

let db_root client_ip =
  "/qubes-firewall/" ^ (Ipaddr.V4.to_string client_ip)

let read_rules rules client_ip =
  let root = db_root client_ip in
  let rec get_rule n l : (Pf_qubes.Parse_qubes.rule list, string) result =
    let pattern = root ^ "/" ^ Printf.sprintf "%04d" n in
    Log.debug (fun f -> f "reading %s" pattern);
    match Qubes.DB.KeyMap.find_opt pattern rules with
    | None ->
      Log.debug (fun f -> f "rule %d does not exist; won't look for more" n);
      Ok (List.rev l)
    | Some rule ->
      Log.debug (fun f -> f "rule %d: %s" n rule);
      match Pf_qubes.Parse_qubes.parse_qubes ~number:n rule with
      | Error e -> Log.warn (fun f -> f "Error parsing rule %d: %s" n e); Error e
      | Ok rule ->
        Log.debug (fun f -> f "parsed rule: %a" Pf_qubes.Parse_qubes.pp_rule rule);
        get_rule (n+1) (rule :: l)
  in
  match get_rule 0 [] with
  | Ok l -> l
  | Error e ->
    Log.warn (fun f -> f "Defaulting to deny-all because of rule parse failure (%s)" e);
    [ Pf_qubes.Parse_qubes.({action = Drop;
                             proto = None;
                             specialtarget = None;
                             dst = `any;
                             dstports = None;
                             icmp_type = None;
                             number = 0;})]

let vifs ~handle domid =
  match String.to_int domid with
  | None -> Log.err (fun f -> f "Invalid domid %S" domid); Lwt.return []
  | Some domid ->
    let path = Printf.sprintf "backend/vif/%d" domid in
    directory ~handle path >>=
    Lwt_list.filter_map_p (fun device_id ->
        match String.to_int device_id with
        | None -> Log.err (fun f -> f "Invalid device ID %S for domid %d" device_id domid); Lwt.return_none
        | Some device_id ->
        let vif = { ClientVif.domid; device_id } in
        Lwt.try_bind
          (fun () -> OS.Xs.read handle (Printf.sprintf "%s/%d/ip" path device_id))
          (fun client_ip ->
             let client_ip = Ipaddr.V4.of_string_exn client_ip in
             Lwt.return (Some (vif, client_ip))
          )
          (function
            | Xs_protocol.Enoent _ -> Lwt.return None
            | ex ->
              Log.err (fun f -> f "Error getting IP address of %a: %s"
                          ClientVif.pp vif (Printexc.to_string ex));
              Lwt.return None
          )
      )

let watch_clients fn =
  OS.Xs.make () >>= fun xs ->
  let backend_vifs = "backend/vif" in
  Log.info (fun f -> f "Watching %s" backend_vifs);
  OS.Xs.wait xs (fun handle ->
    begin Lwt.catch
      (fun () -> directory ~handle backend_vifs)
      (function
        | Xs_protocol.Enoent _ -> Lwt.return []
        | ex -> Lwt.fail ex)
    end >>= fun items ->
    Lwt_list.map_p (vifs ~handle) items >>= fun items ->
    fn (List.concat items |> VifMap.of_list);
    (* Wait for further updates *)
    Lwt.fail Xs_protocol.Eagain
  )

type network_config = {
  uplink_netvm_ip : Ipaddr.V4.t;      (* The IP address of NetVM (our gateway) *)
  uplink_our_ip : Ipaddr.V4.t;        (* The IP address of our interface to NetVM *)

  clients_our_ip : Ipaddr.V4.t;        (* The IP address of our interface to our client VMs (their gateway) *)
}

exception Missing_key of string

(* TODO: /qubes-secondary-dns *)
let try_read_network_config db =
  let get name =
    match DB.KeyMap.find_opt name db with
    | None -> raise (Missing_key name)
    | Some value -> value in
  let uplink_our_ip = get "/qubes-ip" |> Ipaddr.V4.of_string_exn in
  let uplink_netvm_ip = get "/qubes-gateway" |> Ipaddr.V4.of_string_exn in
  let clients_our_ip = get "/qubes-netvm-gateway" |> Ipaddr.V4.of_string_exn in
  Log.info (fun f -> f "@[<v2>Got network configuration from QubesDB:@,\
                        NetVM IP on uplink network: %a@,\
                        Our IP on uplink network:   %a@,\
                        Our IP on client networks:  %a@]"
               Ipaddr.V4.pp uplink_netvm_ip
               Ipaddr.V4.pp uplink_our_ip
               Ipaddr.V4.pp clients_our_ip);
  { uplink_netvm_ip; uplink_our_ip; clients_our_ip }

let read_network_config qubesDB =
  let rec aux bindings =
    try Lwt.return (try_read_network_config bindings)
    with Missing_key key ->
      Log.warn (fun f -> f "QubesDB key %S not (yet) present; waiting for QubesDB to change..." key);
      DB.after qubesDB bindings >>= aux
  in
  aux (DB.bindings qubesDB)

let set_iptables_error db = Qubes.DB.write db "/qubes-iptables-error"
