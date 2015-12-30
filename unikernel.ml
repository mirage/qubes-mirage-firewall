(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt
open Qubes

let src = Logs.Src.create "unikernel" ~doc:"Main unikernel code"
module Log = (val Logs.src_log src : Logs.LOG)

let () =
  let open Logs in
  (* Set default log level *)
  set_level (Some Logs.Info);
  (* Debug-level logging for XenStore while tracking down occasional EACCES error. *)
  Src.list () |> List.find (fun src -> Src.name src = "xenstore.client") |> fun xs ->
  Src.set_level xs (Some Debug)

module Main (Clock : V1.CLOCK) = struct
  module N = Net.Make(Clock)
  module Log_reporter = Mirage_logs.Make(Clock)

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
    let shutdown_rq = OS.Lifecycle.await_shutdown () >|= function `Poweroff | `Reboot -> () in
    (* Set up networking *)
    let net = N.connect qubesDB in
    (* Run until something fails or we get a shutdown request. *)
    Lwt.choose [agent_listener; net; shutdown_rq] >>= fun () ->
    (* Give the console daemon time to show any final log messages. *)
    OS.Time.sleep 1.0
end
