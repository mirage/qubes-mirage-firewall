(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix
open Utils

module Netback = Netchannel.Backend.Make(Netchannel.Xenstore.Make(OS.Xs))
module ClientEth = Ethif.Make(Netback)

let src = Logs.Src.create "client_net" ~doc:"Client networking"
module Log = (val Logs.src_log src : Logs.LOG)

let writev eth data =
  Lwt.catch
    (fun () -> ClientEth.writev eth data)
    (fun ex ->
       (* Usually Netback_shutdown, because the client disconnected *)
       Log.err (fun f -> f "uncaught exception trying to send to client:@\n@[<v2>  %a@]@\nException: @[%s@]"
                   Cstruct.hexdump_pp (Cstruct.concat data) (Printexc.to_string ex));
       Lwt.return ()
    )

class client_iface eth ~gateway_ip ~client_ip client_mac : client_link = object
  val queue = FrameQ.create (Ipaddr.V4.to_string client_ip)
  method my_mac = ClientEth.mac eth
  method other_mac = client_mac
  method my_ip = gateway_ip
  method other_ip = client_ip
  method writev ip =
    FrameQ.send queue (fun () ->
      let eth_hdr = eth_header_ipv4 ~src:(ClientEth.mac eth) ~dst:client_mac in
      writev eth (fixup_checksums (Cstruct.concat (eth_hdr :: ip)))
    )
end

let clients : Cleanup.t Dao.VifMap.t ref = ref Dao.VifMap.empty

(** Handle an ARP message from the client. *)
let input_arp ~fixed_arp ~eth request =
  match Client_eth.ARP.input fixed_arp request with
  | None -> return ()
  | Some response -> writev eth [response]

(** Handle an IPv4 packet from the client. *)
let input_ipv4 ~client_ip ~router frame packet =
  let src = Wire_structs.Ipv4_wire.get_ipv4_src packet |> Ipaddr.V4.of_int32 in
  if src = client_ip then Firewall.ipv4_from_client router frame
  else (
    Log.warn (fun f -> f "Incorrect source IP %a in IP packet from %a (dropping)"
      Ipaddr.V4.pp_hum src Ipaddr.V4.pp_hum client_ip);
    return ()
  )

(** Connect to a new client's interface and listen for incoming frames. *)
let add_vif { Dao.ClientVif.domid; device_id } ~client_ip ~router ~cleanup_tasks =
  Netback.make ~domid ~device_id >>= fun backend ->
  Log.info (fun f -> f "Client %d (IP: %s) ready" domid (Ipaddr.V4.to_string client_ip));
  ClientEth.connect backend >>= or_fail "Can't make Ethernet device" >>= fun eth ->
  let client_mac = Netback.mac backend in
  let client_eth = router.Router.client_eth in
  let gateway_ip = Client_eth.client_gw client_eth in
  let iface = new client_iface eth ~gateway_ip ~client_ip client_mac in
  Router.add_client router iface >>= fun () ->
  Cleanup.on_cleanup cleanup_tasks (fun () -> Router.remove_client router iface);
  let fixed_arp = Client_eth.ARP.create ~net:client_eth iface in
  Netback.listen backend (fun frame ->
    match Wire_structs.parse_ethernet_frame frame with
    | None -> Log.warn (fun f -> f "Invalid Ethernet frame"); return ()
    | Some (typ, _destination, payload) ->
        match typ with
        | Some Wire_structs.ARP -> input_arp ~fixed_arp ~eth payload
        | Some Wire_structs.IPv4 -> input_ipv4 ~client_ip ~router frame payload
        | Some Wire_structs.IPv6 -> return ()
        | None -> Logs.warn (fun f -> f "Unknown Ethernet type"); Lwt.return_unit
  )

(** A new client VM has been found in XenStore. Find its interface and connect to it. *)
let add_client ~router vif client_ip =
  let cleanup_tasks = Cleanup.create () in
  Log.info (fun f -> f "add client vif %a" Dao.ClientVif.pp vif);
  Lwt.async (fun () ->
      Lwt.catch (fun () ->
          add_vif vif ~client_ip ~router ~cleanup_tasks
        )
        (fun ex ->
           Log.warn (fun f -> f "Error connecting client %a: %s"
                        Dao.ClientVif.pp vif (Printexc.to_string ex));
           return ()
        )
    );
  cleanup_tasks

(** Watch XenStore for notifications of new clients. *)
let listen router =
  Dao.watch_clients (fun new_set ->
    (* Check for removed clients *)
    !clients |> Dao.VifMap.iter (fun key cleanup ->
      if not (Dao.VifMap.mem key new_set) then (
        clients := !clients |> Dao.VifMap.remove key;
        Log.info (fun f -> f "client %a has gone" Dao.ClientVif.pp key);
        Cleanup.cleanup cleanup
      )
    );
    (* Check for added clients *)
    new_set |> Dao.VifMap.iter (fun key ip_addr ->
      if not (Dao.VifMap.mem key !clients) then (
        let cleanup = add_client ~router key ip_addr in
        clients := !clients |> Dao.VifMap.add key cleanup
      )
    )
  )
