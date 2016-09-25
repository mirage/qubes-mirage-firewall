(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt
open Qubes

let src = Logs.Src.create "unikernel" ~doc:"Main unikernel code"
module Log = (val Logs.src_log src : Logs.LOG)

module Main (Clock : V1.CLOCK) = struct
  module Uplink = Uplink.Make(Clock)

  (* Set up networking and listen for incoming packets. *)
  let network qubesDB =
    (* Read configuration from QubesDB *)
    let config = Dao.read_network_config qubesDB in
    (* Initialise connection to NetVM *)
    Uplink.connect config >>= fun uplink ->
    (* Report success *)
    Dao.set_iptables_error qubesDB "" >>= fun () ->
    (* Set up client-side networking *)
    let client_eth = Client_eth.create
      ~client_gw:config.Dao.clients_our_ip in
    (* Set up routing between networks and hosts *)
    let router = Router.create
      ~client_eth
      ~uplink:(Uplink.interface uplink) in
    (* Handle packets from both networks *)
    Lwt.join [
      Client_net.listen router;
      Uplink.listen uplink router
    ]

  (* We don't use the GUI, but it's interesting to keep an eye on it.
     If the other end dies, don't let it take us with it (can happen on log out). *)
  let watch_gui gui =
    Lwt.async (fun () ->
      Lwt.try_bind
        (fun () -> GUI.listen gui)
        (fun `Cant_happen -> assert false)
        (fun ex ->
          Log.warn (fun f -> f "GUI thread failed: %s" (Printexc.to_string ex));
          return ()
        )
    )

  (* Main unikernel entry point (called from auto-generated main.ml). *)
  let start () =
    let start_time = Clock.time () in
    (* Start qrexec agent, GUI agent and QubesDB agent in parallel *)
    let qrexec = RExec.connect ~domid:0 () in
    let gui = GUI.connect ~domid:0 () in
    let qubesDB = DB.connect ~domid:0 () in
    (* Wait for clients to connect *)
    qrexec >>= fun qrexec ->
    let agent_listener = RExec.listen qrexec Command.handler in
    gui >>= fun gui ->
    watch_gui gui;
    qubesDB >>= fun qubesDB ->
    Log.info (fun f -> f "agents connected in %.3f s (CPU time used since boot: %.3f s)"
      (Clock.time () -. start_time) (Sys.time ()));
    (* Watch for shutdown requests from Qubes *)
    let shutdown_rq =
      OS.Lifecycle.await_shutdown_request () >>= fun (`Poweroff | `Reboot) ->
      return () in
    (* Set up networking *)
    let net_listener = network qubesDB in
    (* Report memory usage to XenStore *)
    Memory_pressure.init ();
    (* Run until something fails or we get a shutdown request. *)
    Lwt.choose [agent_listener; net_listener; shutdown_rq] >>= fun () ->
    (* Give the console daemon time to show any final log messages. *)
    OS.Time.sleep 1.0
end
