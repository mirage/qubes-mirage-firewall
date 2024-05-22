(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix
open Qubes

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
  Xen_os.Xs.directory handle dir >|= function
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

let vifs client domid =
  let open Lwt.Syntax in
  match int_of_string_opt domid with
  | None -> Log.err (fun f -> f "Invalid domid %S" domid); Lwt.return []
  | Some domid ->
    let path = Fmt.str "backend/vif/%d" domid in
    let vifs_of_domain handle =
      let* devices = directory ~handle path in
      let ip_of_vif device_id = match int_of_string_opt device_id with
        | None ->
          Log.err (fun f -> f "Invalid device ID %S for domid %d" device_id domid);
          Lwt.return_none
        | Some device_id ->
          let vif = { ClientVif.domid; device_id } in
          let get_client_ip () =
            let* str = Xen_os.Xs.read handle (Fmt.str "%s/%d/ip" path device_id) in
            let client_ip = List.hd (String.split_on_char ' ' str) in
            Lwt.return_some (vif, Ipaddr.V4.of_string_exn client_ip)
          in
          Lwt.catch get_client_ip @@ function
          | Xs_protocol.Enoent _ -> Lwt.return_none
          | Ipaddr.Parse_error (msg, client_ip) ->
            Log.err (fun f -> f "Error parsing IP address of %a from %s: %s"
              ClientVif.pp vif client_ip msg);
            Lwt.return_none
          | exn ->
            Log.err (fun f -> f "Error getting IP address of %a: %s"
              ClientVif.pp vif (Printexc.to_string exn));
            Lwt.return_none
      in
      Lwt_list.filter_map_p ip_of_vif devices
    in
    Xen_os.Xs.immediate client vifs_of_domain

let watch_clients fn =
  Xen_os.Xs.make () >>= fun xs ->
  let backend_vifs = "backend/vif" in
  Log.info (fun f -> f "Watching %s" backend_vifs);
  Xen_os.Xs.wait xs (fun handle ->
    begin Lwt.catch
      (fun () -> directory ~handle backend_vifs)
      (function
        | Xs_protocol.Enoent _ -> Lwt.return []
        | ex -> Lwt.fail ex)
    end >>= fun items ->
    Xen_os.Xs.make () >>= fun xs ->
    Lwt_list.map_p (vifs xs) items >>= fun items ->
    fn (List.concat items |> VifMap.of_list);
    (* Wait for further updates *)
    Lwt.fail Xs_protocol.Eagain
  )

type network_config = {
  from_cmdline : bool;         (* Specify if we have network configuration from command line or from qubesDB*)
  netvm_ip : Ipaddr.V4.t;      (* The IP address of NetVM (our gateway) *)
  our_ip : Ipaddr.V4.t;        (* The IP address of our interface to NetVM *)
  dns : Ipaddr.V4.t;
  dns2 : Ipaddr.V4.t;
}

exception Missing_key of string

let try_read_network_config db =
  let get name =
    match DB.KeyMap.find_opt name db with
    | None -> raise (Missing_key name)
    | Some value -> Ipaddr.V4.of_string_exn value in
  let our_ip = get "/qubes-ip" in (* - IP address for this VM (only when VM has netvm set) *)
  let netvm_ip = get "/qubes-gateway" in (* - default gateway IP (only when VM has netvm set); VM should add host route to this address directly via eth0 (or whatever default interface name is) *)
  let dns = get "/qubes-primary-dns" in
  let dns2 = get "/qubes-secondary-dns" in
  { from_cmdline=false; netvm_ip ; our_ip ; dns ; dns2 }

let read_network_config qubesDB =
  let rec aux bindings =
    try Lwt.return (try_read_network_config bindings)
    with Missing_key key ->
      Log.warn (fun f -> f "QubesDB key %S not (yet) present; waiting for QubesDB to change..." key);
      DB.after qubesDB bindings >>= aux
  in
  aux (DB.bindings qubesDB)

let print_network_config config =
  Log.info (fun f -> f "@[<v2>Current network configuration (QubesDB or command line):@,\
                        NetVM IP on uplink network: %a@,\
                        Our IP on client networks:  %a@,\
                        DNS primary resolver:       %a@,\
                        DNS secondary resolver:     %a@]"
               Ipaddr.V4.pp config.netvm_ip
               Ipaddr.V4.pp config.our_ip
               Ipaddr.V4.pp config.dns
               Ipaddr.V4.pp config.dns2)

let set_iptables_error db = Qubes.DB.write db "/qubes-iptables-error"
