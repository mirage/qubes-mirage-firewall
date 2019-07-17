(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt
open Qubes

let src = Logs.Src.create "unikernel" ~doc:"Main unikernel code"
module Log = (val Logs.src_log src : Logs.LOG)

module Main (R : Mirage_types_lwt.RANDOM)(Clock : Mirage_clock_lwt.MCLOCK) = struct
  module Uplink = Uplink.Make(Clock)

  (* Set up networking and listen for incoming packets. *)
  let network ~clock nat qubesDB =
    (* Read configuration from QubesDB *)
    Dao.read_network_config qubesDB >>= fun config ->
    (* Initialise connection to NetVM *)
    Uplink.connect ~clock config >>= fun uplink ->
    (* Report success *)
    Dao.set_iptables_error qubesDB "" >>= fun () ->
    (* Set up client-side networking *)
    let client_eth = Client_eth.create
      ~client_gw:config.Dao.clients_our_ip in
    (* Set up routing between networks and hosts *)
    let router = Router.create
      ~client_eth
      ~uplink:(Uplink.interface uplink)
      ~nat
    in
    (* Handle packets from both networks *)
    Lwt.choose [
      Client_net.listen qubesDB router;
      Uplink.listen uplink router
    ]

  (* We don't use the GUI, but it's interesting to keep an eye on it.
     If the other end dies, don't let it take us with it (can happen on logout). *)
  let watch_gui gui =
    Lwt.async (fun () ->
      Lwt.try_bind
        (fun () ->
           gui >>= fun gui ->
           Log.info (fun f -> f "GUI agent connected");
           GUI.listen gui
        )
        (fun `Cant_happen -> assert false)
        (fun ex ->
          Log.warn (fun f -> f "GUI thread failed: %s" (Printexc.to_string ex));
          return ()
        )
    )

  (* Main unikernel entry point (called from auto-generated main.ml). *)
  let start random clock =
    let start_time = Clock.elapsed_ns clock in
    (* Start qrexec agent, GUI agent and QubesDB agent in parallel *)
    let qrexec = RExec.connect ~domid:0 () in
    GUI.connect ~domid:0 () |> watch_gui;
    let qubesDB = DB.connect ~domid:0 () in

    let server =
      Dns_server.Primary.create ~rng:R.generate Dns_resolver_root.reserved in
    let resolver = Dns_resolver.create ~mode:(`Recursive) start_time R.generate server in

    (* Wait for clients to connect *)
    qrexec >>= fun qrexec ->
    let agent_listener = RExec.listen qrexec Command.handler in
    qubesDB >>= fun qubesDB ->
    let startup_time =
      let (-) = Int64.sub in
      let time_in_ns = Clock.elapsed_ns clock - start_time in
      Int64.to_float time_in_ns /. 1e9
    in
    Log.info (fun f -> f "QubesDB and qrexec agents connected in %.3f s" startup_time);
    (* Watch for shutdown requests from Qubes *)
    let shutdown_rq =
      OS.Lifecycle.await_shutdown_request () >>= fun (`Poweroff | `Reboot) ->
      return () in
    (* Set up networking *)
    let get_time () = Clock.elapsed_ns clock in
    let max_entries = Key_gen.nat_table_size () in
    My_nat.create ~get_time ~max_entries >>= fun nat ->
    let net_listener = network ~clock nat qubesDB in
    (* Report memory usage to XenStore *)
    Memory_pressure.init ();
    (* Run until something fails or we get a shutdown request. *)
    Lwt.choose [agent_listener; net_listener; shutdown_rq] >>= fun () ->
    (* Give the console daemon time to show any final log messages. *)
    OS.Time.sleep_ns (1.0 *. 1e9 |> Int64.of_float)
end
