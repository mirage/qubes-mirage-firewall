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
  let network dns_client dns_responses dns_servers uplink qubesDB router =
    (* Report success *)
    Dao.set_iptables_error qubesDB "" >>= fun () ->
    (* Handle packets from both networks *)
    match uplink with
    | None -> Client_net.listen Clock.elapsed_ns dns_client dns_servers qubesDB router
    | _ ->
      Lwt.choose [
        Client_net.listen Clock.elapsed_ns dns_client dns_servers qubesDB router;
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
    let nat = My_nat.create ~max_entries in

    (* Read network configuration from QubesDB *)
    Dao.read_network_config qubesDB >>= fun config ->
    (* config.netvm_ip might be 0.0.0.0 if there's no netvm provided via Qubes *)

    let connect_if_netvm = 
      if config.netvm_ip <> (Ipaddr.V4.make 0 0 0 0) then (
        Uplink.connect config >>= fun uplink ->
        Lwt.return (config, Some uplink)
      ) else (
      (* If we have no netvm IP address we must not try to Uplink.connect and we can update the config
         with command option (if any) *)
        let netvm_ip = Ipaddr.V4.of_string_exn (Key_gen.ipv4_gw ()) in
        let our_ip = Ipaddr.V4.of_string_exn (Key_gen.ipv4 ()) in
        let dns = Ipaddr.V4.of_string_exn (Key_gen.ipv4_dns ()) in
        let dns2 = Ipaddr.V4.of_string_exn (Key_gen.ipv4_dns2 ()) in
        let default_config:Dao.network_config = {netvm_ip; our_ip; dns; dns2} in
        Dao.update_network_config config default_config >>= fun config ->
        Lwt.return (config, None)
      )
    in
    connect_if_netvm >>= fun (config, uplink) ->

    (* We now must have a valid netvm IP address or crash *)
    Dao.print_network_config config ;
    assert(config.netvm_ip <> (Ipaddr.V4.make 0 0 0 0));

    (* Set up client-side networking *)
    Client_eth.create config >>= fun clients ->

    (* Set up routing between networks and hosts *)
    let router = Router.create
      ~config
      ~clients
      ~nat
      ?uplink:(Uplink.interface uplink)
    in

    let send_dns_query = Uplink.send_dns_client_query uplink in
    let dns_mvar = Lwt_mvar.create_empty () in
    let nameservers = `Udp, [ config.Dao.dns, 53 ; config.Dao.dns2, 53 ] in
    let dns_client = Dns_client.create ~nameservers (router, send_dns_query, dns_mvar) in

    let dns_servers = [ config.Dao.dns ; config.Dao.dns2 ] in
    let net_listener = network (Dns_client.getaddrinfo dns_client Dns.Rr_map.A) dns_mvar dns_servers uplink qubesDB router in

    (* Report memory usage to XenStore *)
    Memory_pressure.init ();
    (* Run until something fails or we get a shutdown request. *)
    Lwt.choose [agent_listener; net_listener; shutdown_rq] >>= fun () ->
    (* Give the console daemon time to show any final log messages. *)
    Time.sleep_ns (1.0 *. 1e9 |> Int64.of_float)
end
