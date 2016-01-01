(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt
open Qubes

let src = Logs.Src.create "unikernel" ~doc:"Main unikernel code"
module Log = (val Logs.src_log src : Logs.LOG)

(* Configure logging *)
let () =
  let open Logs in
  (* Set default log level *)
  set_level (Some Logs.Info);
  (* Debug-level logging for XenStore while tracking down occasional EACCES error. *)
  Src.list () |> List.find (fun src -> Src.name src = "xenstore.client") |> fun xs ->
  Src.set_level xs (Some Debug)

module Main (Clock : V1.CLOCK) = struct
  module Log_reporter = Mirage_logs.Make(Clock)
  module Uplink = Uplink.Make(Clock)

  (* Set up networking and listen for incoming packets. *)
  let network qubesDB =
    (* Read configuration from QubesDB *)
    let config = Dao.read_network_config qubesDB in
    Logs.info "Client (internal) network is %a"
      (fun f -> f Ipaddr.V4.Prefix.pp_hum config.Dao.clients_prefix);
    (* Initialise connection to NetVM *)
    Uplink.connect config >>= fun uplink ->
    (* Report success *)
    Dao.set_iptables_error qubesDB "" >>= fun () ->
    (* Set up client-side networking *)
    let client_eth = Client_eth.create
      ~client_gw:config.Dao.clients_our_ip
      ~prefix:config.Dao.clients_prefix in
    (* Set up routing between networks and hosts *)
    let router = Router.create
      ~client_eth
      ~default_gateway:(Uplink.interface uplink)
      ~my_uplink_ip:(Ipaddr.V4 config.Dao.uplink_our_ip) in
    (* Handle packets from both networks *)
    Lwt.join [
      Client_net.listen router;
      Uplink.listen uplink router
    ]

  (* Main unikernel entry point (called from auto-generated main.ml). *)
  let start () =
    let start_time = Clock.time () in
    Log_reporter.init_logging ();
    (* Start qrexec agent, GUI agent and QubesDB agent in parallel *)
    let qrexec = RExec.connect ~domid:0 () in
    let gui = GUI.connect ~domid:0 () in
    let qubesDB = DB.connect ~domid:0 () in
    (* Wait for clients to connect *)
    qrexec >>= fun qrexec ->
    let agent_listener = RExec.listen qrexec Command.handler in
    gui >>= fun gui ->
    Lwt.async (fun () -> GUI.listen gui);
    qubesDB >>= fun qubesDB ->
    Log.info "agents connected in %.3f s (CPU time used since boot: %.3f s)"
      (fun f -> f (Clock.time () -. start_time) (Sys.time ()));
    (* Watch for shutdown requests from Qubes *)
    let shutdown_rq = OS.Lifecycle.await_shutdown () >>= function `Poweroff | `Reboot -> return () in
    (* Set up networking *)
    let net_listener = network qubesDB in
    (* Run until something fails or we get a shutdown request. *)
    Lwt.choose [agent_listener; net_listener; shutdown_rq] >>= fun () ->
    (* Give the console daemon time to show any final log messages. *)
    OS.Time.sleep 1.0
end
