(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt
open Qubes

let src = Logs.Src.create "unikernel" ~doc:"Main unikernel code"
module Log = (val Logs.src_log src : Logs.LOG)

module Main (R : Mirage_random.S)(Clock : Mirage_clock.MCLOCK)(Time : Mirage_time.S) = struct
  module Uplink = Uplink.Make(R)(Clock)(Time)
  module Dns_transport = My_dns.Transport(R)(Clock)(Time)
  module Dns_client = Dns_client.Make(Dns_transport)

  (* Set up networking and listen for incoming packets. *)
  let network dns_client dns_responses uplink qubesDB router =
    (* Report success *)
    Dao.set_iptables_error qubesDB "" >>= fun () ->
    (* Handle packets from both networks *)
    Lwt.choose [
      Client_net.listen Clock.elapsed_ns dns_client qubesDB router;
      Uplink.listen uplink Clock.elapsed_ns dns_responses router
    ]

  (* Main unikernel entry point (called from auto-generated main.ml). *)
  let start _random _clock _time =
    let start_time = Clock.elapsed_ns () in
    (* Start qrexec agent and QubesDB agent in parallel *)
    let qrexec = RExec.connect ~domid:0 () in
    let qubesDB = DB.connect ~domid:0 () in

    (* Wait for clients to connect *)
    qrexec >>= fun qrexec ->
    let agent_listener = RExec.listen qrexec Command.handler in
    qubesDB >>= fun qubesDB ->
    let startup_time =
      let (-) = Int64.sub in
      let time_in_ns = Clock.elapsed_ns () - start_time in
      Int64.to_float time_in_ns /. 1e9
    in
    Log.info (fun f -> f "QubesDB and qrexec agents connected in %.3f s" startup_time);
    (* Watch for shutdown requests from Qubes *)
    let shutdown_rq =
      Xen_os.Lifecycle.await_shutdown_request () >>= fun (`Poweroff | `Reboot) ->
      Lwt.return_unit in
    (* Set up networking *)
    let max_entries = Key_gen.nat_table_size () in
    My_nat.create ~max_entries >>= fun nat ->

    (* Read network configuration from QubesDB *)
    Dao.read_network_config qubesDB >>= fun config ->

    Uplink.connect config >>= fun uplink ->
    (* Set up client-side networking *)
    let client_eth = Client_eth.create
      ~client_gw:config.Dao.clients_our_ip in
    (* Set up routing between networks and hosts *)
    let router = Router.create
      ~client_eth
      ~uplink:(Uplink.interface uplink)
      ~nat
    in

    let send_dns_query = Uplink.send_dns_client_query uplink in
    let dns_mvar = Lwt_mvar.create_empty () in
    let nameservers = `Udp, [ config.Dao.dns, 53 ] in
    let dns_client = Dns_client.create ~nameservers (router, send_dns_query, dns_mvar) in

    let net_listener = network (Dns_client.getaddrinfo dns_client Dns.Rr_map.A) dns_mvar uplink qubesDB router in

    (* Report memory usage to XenStore *)
    Memory_pressure.init ();
    (* Run until something fails or we get a shutdown request. *)
    Lwt.choose [agent_listener; net_listener; shutdown_rq] >>= fun () ->
    (* Give the console daemon time to show any final log messages. *)
    Time.sleep_ns (1.0 *. 1e9 |> Int64.of_float)
end
