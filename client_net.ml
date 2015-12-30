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
  method client_mac = client_mac
  method client_ip = client_ip
  method writev ip =
    let eth_hdr = eth_header_ipv4 ~src:(ClientEth.mac eth) ~dst:client_mac in
    ClientEth.writev eth (fixup_checksums (Cstruct.concat (eth_hdr :: ip)))
end

let clients : Cleanup.t IntMap.t ref = ref IntMap.empty

let start_client ~router domid =
  let cleanup_tasks = Cleanup.create () in
  Log.info "start_client in domain %d" (fun f -> f domid);
  Lwt.async (fun () ->
    Lwt.catch (fun () ->
      Dao.client_vifs domid >>= (function
      | [] -> return None
      | vif :: others ->
          if others <> [] then Log.warn "Client has multiple interfaces; using first" Logs.unit;
          let { Dao.domid; device_id; client_ip } = vif in
          Netback.make ~domid ~device_id >|= fun backend ->
          Some (backend, client_ip)
      ) >>= function
      | None -> Log.warn "Client has no interfaces" Logs.unit; return ()
      | Some (backend, client_ip) ->
      Log.info "Client %d (IP: %s) ready" (fun f ->
        f domid (Ipaddr.V4.to_string client_ip));
      ClientEth.connect backend >>= or_fail "Can't make Ethernet device" >>= fun eth ->
      let client_mac = Netback.mac backend in
      let iface = new client_iface eth client_ip client_mac in
      let fixed_arp = Client_eth.ARP.create ~net:(Router.client_eth router) iface in
      Router.add_client router iface;
      Cleanup.on_cleanup cleanup_tasks (fun () -> Router.remove_client router iface);
      Netback.listen backend (
        ClientEth.input
          ~arpv4:(fun buf ->
            match Client_eth.ARP.input fixed_arp buf with
            | None -> return ()
            | Some frame -> ClientEth.write eth frame
          )
          ~ipv4:(fun packet ->
            let src = Wire_structs.Ipv4_wire.get_ipv4_src packet |> Ipaddr.V4.of_int32 in
            if src === client_ip then Router.forward_ipv4 router packet
            else (
              Log.warn "Incorrect source IP %a in IP packet from %a (dropping)"
                (fun f -> f Ipaddr.V4.pp_hum src Ipaddr.V4.pp_hum client_ip);
              return ()
            )
          )
          ~ipv6:(fun _buf -> return ())
          eth
      )
    )
    (fun ex ->
      Log.warn "Error connecting client domain %d: %s"
        (fun f -> f domid (Printexc.to_string ex));
      return ()
    )
  );
  cleanup_tasks

let listen router =
  let backend_vifs = "backend/vif" in
  Log.info "Watching %s" (fun f -> f backend_vifs);
  Dao.watch_clients (fun new_set ->
    (* Check for removed clients *)
    !clients |> IntMap.iter (fun key cleanup ->
      if not (IntSet.mem key new_set) then (
        clients := !clients |> IntMap.remove key;
        Log.info "stop_client %d" (fun f -> f key);
        Cleanup.cleanup cleanup
      )
    );
    (* Check for added clients *)
    new_set |> IntSet.iter (fun key ->
      if not (IntMap.mem key !clients) then (
        let cleanup = start_client ~router key in
        clients := !clients |> IntMap.add key cleanup
      )
    )
  )
