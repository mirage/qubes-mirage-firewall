(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt
open Qubes
open Cmdliner

let src = Logs.Src.create "unikernel" ~doc:"Main unikernel code"
module Log = (val Logs.src_log src : Logs.LOG)

let nat_table_size =
  let doc = Arg.info ~doc:"The number of NAT entries to allocate." [ "nat-table-size" ] in
  Arg.(value & opt int 5_000 doc)

let ipv4 =
  let doc = Arg.info ~doc:"Manual IP setting." [ "ipv4" ] in
  Arg.(value & opt string "0.0.0.0" doc)

let ipv4_gw =
  let doc = Arg.info ~doc:"Manual Gateway IP setting." [ "ipv4-gw" ] in
  Arg.(value & opt string "0.0.0.0" doc)

let ipv4_dns =
  let doc = Arg.info ~doc:"Manual DNS IP setting." [ "ipv4-dns" ] in
  Arg.(value & opt string "10.139.1.1" doc)

let ipv4_dns2 =
  let doc = Arg.info ~doc:"Manual Second DNS IP setting." [ "ipv4-dns2" ] in
  Arg.(value & opt string "10.139.1.2" doc)

module Main (R : Mirage_random.S)(Clock : Mirage_clock.MCLOCK)(Time : Mirage_time.S) = struct
  module Dispatcher = Dispatcher.Make(R)(Clock)(Time)
  module Dns_transport = My_dns.Transport(R)(Clock)(Time)
  module Dns_client = Dns_client.Make(Dns_transport)

  (* Set up networking and listen for incoming packets. *)
  let network dns_client dns_responses dns_servers qubesDB router =
    (* Report success *)
    Dao.set_iptables_error qubesDB "" >>= fun () ->
    (* Handle packets from both networks *)
    Lwt.choose [
      Dispatcher.wait_clients Clock.elapsed_ns dns_client dns_servers qubesDB router ;
      Dispatcher.uplink_wait_update qubesDB router ;
      Dispatcher.uplink_listen Clock.elapsed_ns dns_responses router
    ]

  (* Main unikernel entry point (called from auto-generated main.ml). *)
  let start _random _clock _time nat_table_size ipv4 ipv4_gw ipv4_dns ipv4_dns2 =
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
    let nat = My_nat.create ~max_entries:nat_table_size in

    let netvm_ip = Ipaddr.V4.of_string_exn ipv4_gw in
    let our_ip = Ipaddr.V4.of_string_exn ipv4 in
    let dns = Ipaddr.V4.of_string_exn ipv4_dns in
    let dns2 = Ipaddr.V4.of_string_exn ipv4_dns2 in
    
    let zero_ip = (Ipaddr.V4.make 0 0 0 0) in
    
    let network_config  =
      if (netvm_ip = zero_ip && our_ip = zero_ip) then (* Read network configuration from QubesDB *)
        Dao.read_network_config qubesDB >>= fun config ->
        if config.netvm_ip = zero_ip || config.our_ip = zero_ip then
          Log.info (fun f -> f "We currently have no netvm nor command line for setting it up, aborting...");
        assert (config.netvm_ip <> zero_ip && config.our_ip <> zero_ip);
        Lwt.return config
      else begin
        let config:Dao.network_config = {from_cmdline=true; netvm_ip; our_ip; dns; dns2} in
        Lwt.return config
      end
    in
    network_config >>= fun config ->

    (* We now must have a valid netvm IP address and our IP address or crash *)
    Dao.print_network_config config ;

    (* Set up client-side networking *)
    Client_eth.create config >>= fun clients ->

    (* Set up routing between networks and hosts *)
    let router = Dispatcher.create
      ~config
      ~clients
      ~nat
      ?uplink:None
    in

    let send_dns_query = Dispatcher.send_dns_client_query None in
    let dns_mvar = Lwt_mvar.create_empty () in
    let nameservers = `Udp, [ config.Dao.dns, 53 ; config.Dao.dns2, 53 ] in
    let dns_client = Dns_client.create ~nameservers (router, send_dns_query, dns_mvar) in

    let dns_servers = [ config.Dao.dns ; config.Dao.dns2 ] in
    let net_listener = network (Dns_client.getaddrinfo dns_client Dns.Rr_map.A) dns_mvar dns_servers qubesDB router in

    (* Report memory usage to XenStore *)
    Memory_pressure.init ();
    (* Run until something fails or we get a shutdown request. *)
    Lwt.choose [agent_listener; net_listener; shutdown_rq] >>= fun () ->
    (* Give the console daemon time to show any final log messages. *)
    Time.sleep_ns (1.0 *. 1e9 |> Int64.of_float)
end
