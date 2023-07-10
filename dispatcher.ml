open Lwt.Infix
open Fw_utils
module Netback = Netchannel.Backend.Make (Netchannel.Xenstore.Make (Xen_os.Xs))
module ClientEth = Ethernet.Make (Netback)
module UplinkEth = Ethernet.Make (Netif)

let src = Logs.Src.create "dispatcher" ~doc:"Networking dispatch"

module Log = (val Logs.src_log src : Logs.LOG)

module Make
    (R : Mirage_random.S)
    (Clock : Mirage_clock.MCLOCK)
    (Time : Mirage_time.S) =
struct
  module Arp = Arp.Make (UplinkEth) (Time)
  module I = Static_ipv4.Make (R) (Clock) (UplinkEth) (Arp)
  module U = Udp.Make (I) (R)

  let clients : Cleanup.t Dao.VifMap.t ref = ref Dao.VifMap.empty

  class client_iface eth ~domid ~gateway_ip ~client_ip client_mac : client_link
    =
    let log_header = Fmt.str "dom%d:%a" domid Ipaddr.V4.pp client_ip in
    object
      val mutable rules = []
      method get_rules = rules
      method set_rules new_db = rules <- Dao.read_rules new_db client_ip
      method my_mac = ClientEth.mac eth
      method other_mac = client_mac
      method my_ip = gateway_ip
      method other_ip = client_ip

      method writev proto fillfn =
        Lwt.catch
          (fun () ->
            ClientEth.write eth client_mac proto fillfn >|= function
            | Ok () -> ()
            | Error e ->
                Log.err (fun f ->
                    f "error trying to send to client: @[%a@]"
                      ClientEth.pp_error e))
          (fun ex ->
            (* Usually Netback_shutdown, because the client disconnected *)
            Log.err (fun f ->
                f "uncaught exception trying to send to client: @[%s@]"
                  (Printexc.to_string ex));
            Lwt.return_unit)

      method log_header = log_header
    end

  class netvm_iface eth mac ~my_ip ~other_ip : interface =
    object
      method my_mac = UplinkEth.mac eth
      method my_ip = my_ip
      method other_ip = other_ip

      method writev ethertype fillfn =
        mac >>= fun dst ->
        UplinkEth.write eth dst ethertype fillfn
        >|= or_raise "Write to uplink" UplinkEth.pp_error
    end

  type uplink = {
    net : Netif.t;
    eth : UplinkEth.t;
    arp : Arp.t;
    interface : interface;
    mutable fragments : Fragments.Cache.t;
    ip : I.t;
    udp : U.t;
  }

  type t = {
    uplink_wait_config : unit Lwt_condition.t;
    mutable config : Dao.network_config;
    clients : Client_eth.t;
    nat : My_nat.t;
    mutable uplink : uplink option;
  }

  let create ~config ~clients ~nat ?uplink =
    {
      uplink_wait_config = Lwt_condition.create ();
      config;
      clients;
      nat;
      uplink;
    }

  let update t ~config ?uplink =
    t.config <- config;
    t.uplink <- uplink;
    Lwt.return_unit

  let target t buf =
    let dst_ip = buf.Ipv4_packet.dst in
    match Client_eth.lookup t.clients dst_ip with
    | Some client_link -> Some (client_link :> interface)
    | None -> ( (* if dest is not a client, transfer it to our uplink *)
        match t.uplink with
        | None -> (
            match Client_eth.lookup t.clients t.config.netvm_ip with
            | Some uplink ->
              Some (uplink :> interface)
            | None ->
              Log.err (fun f -> f "We have a command line configuration %a but it's currently not connected to us (please check its netvm property)...%!" Ipaddr.V4.pp t.config.netvm_ip);
              None)
        | Some uplink -> Some uplink.interface)

  let add_client t = Client_eth.add_client t.clients
  let remove_client t = Client_eth.remove_client t.clients

  let classify t ip =
    if ip = Ipaddr.V4 t.config.our_ip then `Firewall
    else if ip = Ipaddr.V4 t.config.netvm_ip then `NetVM
    else (Client_eth.classify t.clients ip :> Packet.host)

  let resolve t = function
    | `Firewall -> Ipaddr.V4 t.config.our_ip
    | `NetVM -> Ipaddr.V4 t.config.netvm_ip
    | #Client_eth.host as host -> Client_eth.resolve t.clients host

  (* Transmission *)

  let transmit_ipv4 packet iface =
    Lwt.catch
      (fun () ->
        let fragments = ref [] in
        iface#writev `IPv4 (fun b ->
            match Nat_packet.into_cstruct packet b with
            | Error e ->
                Log.warn (fun f ->
                    f "Failed to write packet to %a: %a" Ipaddr.V4.pp
                      iface#other_ip Nat_packet.pp_error e);
                0
            | Ok (n, frags) ->
                fragments := frags;
                n)
        >>= fun () ->
        Lwt_list.iter_s
          (fun f ->
            let size = Cstruct.length f in
            iface#writev `IPv4 (fun b ->
                Cstruct.blit f 0 b 0 size;
                size))
          !fragments)
      (fun ex ->
        Log.warn (fun f ->
            f "Failed to write packet to %a: %s" Ipaddr.V4.pp iface#other_ip
              (Printexc.to_string ex));
        Lwt.return_unit)

  let forward_ipv4 t packet =
    let (`IPv4 (ip, _)) = packet in
    match target t ip with
    | Some iface -> transmit_ipv4 packet iface
    | None -> Lwt.return_unit

  (* NAT *)

  let translate t packet = My_nat.translate t.nat packet

  (* Add a NAT rule for the endpoints in this frame, via a random port on the firewall. *)
  let add_nat_and_forward_ipv4 t packet =
    let xl_host = t.config.our_ip in
    match My_nat.add_nat_rule_and_translate t.nat ~xl_host `NAT packet with
    | Ok packet -> forward_ipv4 t packet
    | Error e ->
        Log.warn (fun f ->
            f "Failed to add NAT rewrite rule: %s (%a)" e Nat_packet.pp packet);
        Lwt.return_unit

  (* Add a NAT rule to redirect this conversation to [host:port] instead of us. *)
  let nat_to t ~host ~port packet =
    match resolve t host with
    | Ipaddr.V6 _ ->
        Log.warn (fun f -> f "Cannot NAT with IPv6");
        Lwt.return_unit
    | Ipaddr.V4 target -> (
        let xl_host = t.config.our_ip in
        match
          My_nat.add_nat_rule_and_translate t.nat ~xl_host
            (`Redirect (target, port))
            packet
        with
        | Ok packet -> forward_ipv4 t packet
        | Error e ->
            Log.warn (fun f ->
                f "Failed to add NAT redirect rule: %s (%a)" e Nat_packet.pp
                  packet);
            Lwt.return_unit)

  let apply_rules t (rules : ('a, 'b) Packet.t -> Packet.action Lwt.t) ~dst
      (annotated_packet : ('a, 'b) Packet.t) : unit Lwt.t =
    let packet = Packet.to_mirage_nat_packet annotated_packet in
    rules annotated_packet >>= fun action ->
    match (action, dst) with
    | `Accept, `Client client_link -> transmit_ipv4 packet client_link
    | `Accept, (`External _ | `NetVM) -> (
        match t.uplink with
        | Some uplink -> transmit_ipv4 packet uplink.interface
        | None -> (
            match Client_eth.lookup t.clients t.config.netvm_ip with
            | Some iface -> transmit_ipv4 packet iface
            | None ->
                Log.warn (fun f ->
                    f "No output interface for %a : drop" Nat_packet.pp packet);
                Lwt.return_unit))
    | `Accept, `Firewall ->
        Log.warn (fun f ->
            f "Bad rule: firewall can't accept packets %a" Nat_packet.pp packet);
        Lwt.return_unit
    | `NAT, _ ->
        Log.debug (fun f -> f "adding NAT rule for %a" Nat_packet.pp packet);
        add_nat_and_forward_ipv4 t packet
    | `NAT_to (host, port), _ -> nat_to t packet ~host ~port
    | `Drop reason, _ ->
        Log.debug (fun f ->
            f "Dropped packet (%s) %a" reason Nat_packet.pp packet);
        Lwt.return_unit

  let ipv4_from_netvm t packet =
    match Memory_pressure.status () with
    | `Memory_critical -> Lwt.return_unit
    | `Ok -> (
        let (`IPv4 (ip, _transport)) = packet in
        let src = classify t (Ipaddr.V4 ip.Ipv4_packet.src) in
        let dst = classify t (Ipaddr.V4 ip.Ipv4_packet.dst) in
        match Packet.of_mirage_nat_packet ~src ~dst packet with
        | None -> Lwt.return_unit
        | Some _ -> (
            match src with
            | `Client _ | `Firewall ->
                Log.warn (fun f ->
                    f "Frame from NetVM has internal source IP address! %a"
                      Nat_packet.pp packet);
                Lwt.return_unit
            | (`External _ | `NetVM) as src -> (
                match translate t packet with
                | Some frame -> forward_ipv4 t frame
                | None -> (
                    match Packet.of_mirage_nat_packet ~src ~dst packet with
                    | None -> Lwt.return_unit
                    | Some packet -> apply_rules t Rules.from_netvm ~dst packet)
                )))

  let ipv4_from_client resolver dns_servers t ~src packet =
    match Memory_pressure.status () with
    | `Memory_critical -> Lwt.return_unit
    | `Ok -> (
        (* Check for existing NAT entry for this packet *)
        match translate t packet with
        | Some frame ->
            forward_ipv4 t frame (* Some existing connection or redirect *)
        | None -> (
            (* No existing NAT entry. Check the firewall rules. *)
            let (`IPv4 (ip, _transport)) = packet in
            match classify t (Ipaddr.V4 ip.Ipv4_packet.src) with
            | `Client _ | `Firewall -> (
                let dst = classify t (Ipaddr.V4 ip.Ipv4_packet.dst) in
                match
                  Packet.of_mirage_nat_packet ~src:(`Client src) ~dst packet
                with
                | None -> Lwt.return_unit
                | Some firewall_packet ->
                    apply_rules t
                      (Rules.from_client resolver dns_servers)
                      ~dst firewall_packet)
            | `NetVM -> ipv4_from_netvm t packet
            | `External _ ->
                Log.warn (fun f ->
                    f "Frame from Inside has external source IP address! %a"
                      Nat_packet.pp packet);
                Lwt.return_unit))

  (** Handle an ARP message from the client. *)
  let client_handle_arp ~fixed_arp ~iface request =
    match Arp_packet.decode request with
    | Error e ->
        Log.warn (fun f ->
            f "Ignored unknown ARP message: %a" Arp_packet.pp_error e);
        Lwt.return_unit
    | Ok arp -> (
        match Client_eth.ARP.input fixed_arp arp with
        | None -> Lwt.return_unit
        | Some response ->
            iface#writev `ARP (fun b ->
                Arp_packet.encode_into response b;
                Arp_packet.size))

  (** Handle an IPv4 packet from the client. *)
  let client_handle_ipv4 get_ts cache ~iface ~router dns_client dns_servers
      packet =
    let cache', r = Nat_packet.of_ipv4_packet !cache ~now:(get_ts ()) packet in
    cache := cache';
    match r with
    | Error e ->
        Log.warn (fun f ->
            f "Ignored unknown IPv4 message: %a" Nat_packet.pp_error e);
        Lwt.return_unit
    | Ok None -> Lwt.return_unit
    | Ok (Some packet) ->
        let (`IPv4 (ip, _)) = packet in
        let src = ip.Ipv4_packet.src in
        if src = iface#other_ip then
          ipv4_from_client dns_client dns_servers router ~src:iface packet
        else (
          Log.warn (fun f ->
              f "Incorrect source IP %a in IP packet from %a (dropping)"
                Ipaddr.V4.pp src Ipaddr.V4.pp iface#other_ip);
          Lwt.return_unit)

  (** Connect to a new client's interface and listen for incoming frames and firewall rule changes. *)
  let add_vif get_ts { Dao.ClientVif.domid; device_id } dns_client dns_servers
      ~client_ip ~router ~cleanup_tasks qubesDB =
    Netback.make ~domid ~device_id >>= fun backend ->
    Log.info (fun f ->
        f "Client %d (IP: %s) ready" domid (Ipaddr.V4.to_string client_ip));
    ClientEth.connect backend >>= fun eth ->
    let client_mac = Netback.frontend_mac backend in
    let client_eth = router.clients in
    let gateway_ip = Client_eth.client_gw client_eth in
    let iface = new client_iface eth ~domid ~gateway_ip ~client_ip client_mac in
    (* update the rules whenever QubesDB notices a change for this IP *)
    let qubesdb_updater =
      Lwt.catch
        (fun () ->
          let rec update current_db current_rules =
            Qubes.DB.got_new_commit qubesDB (Dao.db_root client_ip) current_db
            >>= fun new_db ->
            iface#set_rules new_db;
            let new_rules = iface#get_rules in
            if current_rules = new_rules then
              Log.info (fun m ->
                  m "Rules did not change for %s"
                    (Ipaddr.V4.to_string client_ip))
            else (
              Log.info (fun m ->
                  m "New firewall rules for %s@.%a"
                    (Ipaddr.V4.to_string client_ip)
                    Fmt.(list ~sep:(any "@.") Pf_qubes.Parse_qubes.pp_rule)
                    new_rules);
              (* empty NAT table if rules are updated: they might deny old connections *)
              My_nat.remove_connections router.nat client_ip);
            update new_db new_rules
          in
          update Qubes.DB.KeyMap.empty [])
        (function Lwt.Canceled -> Lwt.return_unit | e -> Lwt.fail e)
    in
    Cleanup.on_cleanup cleanup_tasks (fun () -> Lwt.cancel qubesdb_updater);
    add_client router iface >>= fun () ->
    Cleanup.on_cleanup cleanup_tasks (fun () -> remove_client router iface);
    let fixed_arp = Client_eth.ARP.create ~net:client_eth iface in
    let fragment_cache = ref (Fragments.Cache.empty (256 * 1024)) in
    let listener =
      Lwt.catch
        (fun () ->
          Netback.listen backend ~header_size:Ethernet.Packet.sizeof_ethernet
            (fun frame ->
              match Ethernet.Packet.of_cstruct frame with
              | Error err ->
                  Log.warn (fun f -> f "Invalid Ethernet frame: %s" err);
                  Lwt.return_unit
              | Ok (eth, payload) -> (
                  match eth.Ethernet.Packet.ethertype with
                  | `ARP -> client_handle_arp ~fixed_arp ~iface payload
                  | `IPv4 ->
                      client_handle_ipv4 get_ts fragment_cache ~iface ~router
                        dns_client dns_servers payload
                  | `IPv6 -> Lwt.return_unit (* TODO: oh no! *)))
          >|= or_raise "Listen on client interface" Netback.pp_error)
        (function Lwt.Canceled -> Lwt.return_unit | e -> Lwt.fail e)
    in
    Cleanup.on_cleanup cleanup_tasks (fun () -> Lwt.cancel listener);
    Lwt.pick [ qubesdb_updater; listener ]

  (** A new client VM has been found in XenStore. Find its interface and connect to it. *)
  let add_client get_ts dns_client dns_servers ~router vif client_ip qubesDB =
    let cleanup_tasks = Cleanup.create () in
    Log.info (fun f ->
        f "add client vif %a with IP %a" Dao.ClientVif.pp vif Ipaddr.V4.pp
          client_ip);
    Lwt.async (fun () ->
        Lwt.catch
          (fun () ->
            add_vif get_ts vif dns_client dns_servers ~client_ip ~router
              ~cleanup_tasks qubesDB)
          (fun ex ->
            Log.warn (fun f ->
                f "Error with client %a: %s" Dao.ClientVif.pp vif
                  (Printexc.to_string ex));
            Lwt.return_unit));
    cleanup_tasks

  (** Watch XenStore for notifications of new clients. *)
  let wait_clients get_ts dns_client dns_servers qubesDB router =
    Dao.watch_clients (fun new_set ->
        (* Check for removed clients *)
        !clients
        |> Dao.VifMap.iter (fun key cleanup ->
               if not (Dao.VifMap.mem key new_set) then (
                 clients := !clients |> Dao.VifMap.remove key;
                 Log.info (fun f -> f "client %a has gone" Dao.ClientVif.pp key);
                 Cleanup.cleanup cleanup));
        (* Check for added clients *)
        new_set
        |> Dao.VifMap.iter (fun key ip_addr ->
               if not (Dao.VifMap.mem key !clients) then (
                 let cleanup =
                   add_client get_ts dns_client dns_servers ~router key ip_addr
                     qubesDB
                 in
                 Log.debug (fun f -> f "client %a arrived" Dao.ClientVif.pp key);
                 clients := !clients |> Dao.VifMap.add key cleanup)))

  let send_dns_client_query t ~src_port ~dst ~dst_port buf =
    match t with
    | None ->
        Log.err (fun f -> f "No uplink interface");
        Lwt.return (Error (`Msg "failure"))
    | Some t -> (
        U.write ~src_port ~dst ~dst_port t.udp buf >|= function
        | Error s ->
            Log.err (fun f -> f "error sending udp packet: %a" U.pp_error s);
            Error (`Msg "failure")
        | Ok () -> Ok ())

  (** Wait for packet from our uplink (we must have an uplink here...). *)
  let rec uplink_listen get_ts dns_responses router =
    let handle_packet ip_header ip_packet =
      let open Udp_packet in
      Log.debug (fun f ->
          f "received ipv4 packet from %a on uplink" Ipaddr.V4.pp
            ip_header.Ipv4_packet.src);
      match ip_packet with
      | `UDP (header, packet) when My_nat.dns_port router.nat header.dst_port ->
          Log.debug (fun f ->
              f
                "found a DNS packet whose dst_port (%d) was in the list of \
                 dns_client ports"
                header.dst_port);
          Lwt_mvar.put dns_responses (header, packet)
      | _ -> ipv4_from_netvm router (`IPv4 (ip_header, ip_packet))
    in
    match router.uplink with
    | None ->
        Lwt_condition.wait router.uplink_wait_config >>= fun () ->
        uplink_listen get_ts dns_responses router
    | Some uplink ->
        let listen =
          Netif.listen uplink.net ~header_size:Ethernet.Packet.sizeof_ethernet
            (fun frame ->
              (* Handle one Ethernet frame from NetVM *)
              UplinkEth.input uplink.eth ~arpv4:(Arp.input uplink.arp)
                ~ipv4:(fun ip ->
                  let cache, r =
                    Nat_packet.of_ipv4_packet uplink.fragments ~now:(get_ts ())
                      ip
                  in
                  uplink.fragments <- cache;
                  match r with
                  | Error e ->
                      Log.warn (fun f ->
                          f "Ignored unknown IPv4 message from uplink: %a"
                            Nat_packet.pp_error e);
                      Lwt.return ()
                  | Ok None -> Lwt.return_unit
                  | Ok (Some (`IPv4 (header, packet))) ->
                      handle_packet header packet)
                ~ipv6:(fun _ip -> Lwt.return_unit)
                frame)
          >|= or_raise "Uplink listen loop" Netif.pp_error
        in
        let reconnect_uplink =
          Lwt_condition.wait router.uplink_wait_config >>= fun () ->
          uplink_listen get_ts dns_responses router
        in
        Lwt.pick [ listen; reconnect_uplink ]

  (** Connect to our uplink backend (we must have an uplink here...). *)
  let connect config =
    let my_ip = config.Dao.our_ip in
    let gateway = config.Dao.netvm_ip in
    Netif.connect "0" >>= fun net ->
    UplinkEth.connect net >>= fun eth ->
    Arp.connect eth >>= fun arp ->
    Arp.add_ip arp my_ip >>= fun () ->
    let cidr = Ipaddr.V4.Prefix.make 0 my_ip in
    I.connect ~cidr ~gateway eth arp >>= fun ip ->
    U.connect ip >>= fun udp ->
    let netvm_mac =
      Arp.query arp gateway >|= or_raise "Getting MAC of our NetVM" Arp.pp_error
    in
    let interface =
      new netvm_iface eth netvm_mac ~my_ip ~other_ip:config.Dao.netvm_ip
    in
    let fragments = Fragments.Cache.empty (256 * 1024) in
    Lwt.return { net; eth; arp; interface; fragments; ip; udp }

  (** Wait Xenstore for our uplink changes (we must have an uplink here...). *)
  let uplink_wait_update qubesDB router =
    let rec aux current_db =
      let netvm = "/qubes-gateway" in
      Log.info (fun f -> f "Waiting for netvm changes from %S...%!" netvm);
      Qubes.DB.after qubesDB current_db >>= fun new_db ->
      (match (router.uplink, Qubes.DB.KeyMap.find_opt netvm new_db) with
      | Some uplink, Some netvm
        when not
               (String.equal netvm
                  (Ipaddr.V4.to_string uplink.interface#other_ip)) ->
          Log.info (fun f ->
              f "Our netvm IP has changed, before it was %s, now it's: %s%!"
                (Ipaddr.V4.to_string uplink.interface#other_ip)
                netvm);
          Netif.disconnect uplink.net;
          Dao.read_network_config qubesDB >>= fun config ->
          Dao.print_network_config config;
          Time.sleep_ns (Duration.of_sec 1) >>= fun () ->
          (* We need to wait for uplink_listen callback to be killed off *)
          connect config >>= fun uplink ->
          update router ~config ?uplink:(Some uplink) >>= fun () ->
          Lwt_condition.broadcast router.uplink_wait_config ();
          Lwt.return_unit
      | None, Some _ ->
          (* a new interface is attributed to qubes-mirage-firewall *)
          Log.info (fun f -> f "Going from netvm not connected to %s%!" netvm);
          Dao.read_network_config qubesDB >>= fun config ->
          Dao.print_network_config config;
          connect config >>= fun uplink ->
          update router ~config ?uplink:(Some uplink) >>= fun () ->
          Lwt_condition.broadcast router.uplink_wait_config ();
          Lwt.return_unit
      | Some uplink, None ->
          (* qubes-mirage-firewall now have netvm set to none: this is currently not supported... *)
          Log.info (fun f ->
              f "TODO: Our netvm disapeared, troubles are coming!%!");
          Netif.disconnect uplink.net;
          Dao.read_network_config qubesDB >>= fun config ->
          update router ~config ?uplink:None
      | Some _, Some _ (* The new netvm IP is unchanged (it's our old netvm IP) *)
      | None, None  ->
          Log.info (fun f ->
              f "QubesDB has changed but not the situation of our netvm!%!");
          Lwt.return_unit)
      >>= fun () -> aux new_db
    in
    aux Qubes.DB.KeyMap.empty
end
