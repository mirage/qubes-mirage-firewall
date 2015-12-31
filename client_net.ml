(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix
open Utils

module Netback = Netchannel.Backend.Make(Netchannel.Xenstore.Make(OS.Xs))
module ClientEth = Ethif.Make(Netback)

let src = Logs.Src.create "net" ~doc:"Client networking"
module Log = (val Logs.src_log src : Logs.LOG)

class client_iface eth client_ip client_mac : client_link = object
  method my_mac = ClientEth.mac eth
  method other_mac = client_mac
  method other_ip = client_ip
  method writev ip =
    let eth_hdr = eth_header_ipv4 ~src:(ClientEth.mac eth) ~dst:client_mac in
    ClientEth.writev eth (fixup_checksums (Cstruct.concat (eth_hdr :: ip)))
end

let clients : Cleanup.t IntMap.t ref = ref IntMap.empty

(** Handle an ARP message from the client. *)
let input_arp ~fixed_arp ~eth request =
  match Client_eth.ARP.input fixed_arp request with
  | None -> return ()
  | Some response -> ClientEth.write eth response

(** Handle an IPv4 packet from the client. *)
let input_ipv4 ~client_ip ~router frame packet =
  let src = Wire_structs.Ipv4_wire.get_ipv4_src packet |> Ipaddr.V4.of_int32 in
  if src === client_ip then Firewall.ipv4_from_client router frame
  else (
    Log.warn "Incorrect source IP %a in IP packet from %a (dropping)"
      (fun f -> f Ipaddr.V4.pp_hum src Ipaddr.V4.pp_hum client_ip);
    return ()
  )

(** Connect to a new client's interface and listen for incoming frames. *)
let add_vif { Dao.domid; device_id; client_ip } ~router ~cleanup_tasks =
  Netback.make ~domid ~device_id >>= fun backend ->
  Log.info "Client %d (IP: %s) ready" (fun f ->
    f domid (Ipaddr.V4.to_string client_ip));
  ClientEth.connect backend >>= or_fail "Can't make Ethernet device" >>= fun eth ->
  let client_mac = Netback.mac backend in
  let iface = new client_iface eth client_ip client_mac in
  Router.add_client router iface;
  Cleanup.on_cleanup cleanup_tasks (fun () -> Router.remove_client router iface);
  let fixed_arp = Client_eth.ARP.create ~net:router.Router.client_eth iface in
  Netback.listen backend (fun frame ->
    match Wire_structs.parse_ethernet_frame frame with
    | None -> Log.warn "Invalid Ethernet frame" Logs.unit; return ()
    | Some (typ, _destination, payload) ->
        match typ with
        | Some Wire_structs.ARP -> input_arp ~fixed_arp ~eth payload
        | Some Wire_structs.IPv4 -> input_ipv4 ~client_ip ~router frame payload
        | Some Wire_structs.IPv6 -> return ()
        | None -> Logs.warn "Unknown Ethernet type" Logs.unit; Lwt.return_unit
  )

(** A new client VM has been found in XenStore. Find its interface and connect to it. *)
let add_client ~router domid =
  let cleanup_tasks = Cleanup.create () in
  Log.info "add client domain %d" (fun f -> f domid);
  Lwt.async (fun () ->
    Lwt.catch (fun () ->
      Dao.client_vifs domid >>= function
      | [] ->
          Log.warn "Client has no interfaces" Logs.unit;
          return ()
      | vif :: others ->
          if others <> [] then Log.warn "Client has multiple interfaces; using first" Logs.unit;
          add_vif vif ~router ~cleanup_tasks
    )
    (fun ex ->
      Log.warn "Error connecting client domain %d: %s"
        (fun f -> f domid (Printexc.to_string ex));
      return ()
    )
  );
  cleanup_tasks

(** Watch XenStore for notifications of new clients. *)
let listen router =
  let backend_vifs = "backend/vif" in
  Log.info "Watching %s" (fun f -> f backend_vifs);
  Dao.watch_clients (fun new_set ->
    (* Check for removed clients *)
    !clients |> IntMap.iter (fun key cleanup ->
      if not (IntSet.mem key new_set) then (
        clients := !clients |> IntMap.remove key;
        Log.info "client %d has gone" (fun f -> f key);
        Cleanup.cleanup cleanup
      )
    );
    (* Check for added clients *)
    new_set |> IntSet.iter (fun key ->
      if not (IntMap.mem key !clients) then (
        let cleanup = add_client ~router key in
        clients := !clients |> IntMap.add key cleanup
      )
    )
  )
