(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** General network stuff (needs reorganising). *)

open Lwt.Infix
open Utils

module Eth = Ethif.Make(Netif)

module Netback = Netchannel.Backend.Make(Netchannel.Xenstore.Make(OS.Xs))
module ClientEth = Ethif.Make(Netback)

let src = Logs.Src.create "net" ~doc:"Firewall networking"
module Log = (val Logs.src_log src : Logs.LOG)

module Make(Clock : V1.CLOCK) = struct
  module Arp = Arpv4.Make(Eth)(Clock)(OS.Time)
  module IPv4 = Ipv4.Make(Eth)(Arp)
  module Xs = OS.Xs

  class netvm_iface eth my_ip mac nat_table : interface = object
    method my_mac = Eth.mac eth
    method writev ip =
      mac >>= fun dst ->
      let eth_hdr = eth_header_ipv4 ~src:(Eth.mac eth) ~dst in
      match Nat_rules.nat my_ip nat_table Nat_rewrite.Source (Cstruct.concat (eth_hdr :: ip)) with
      | None -> return ()
      | Some frame -> Eth.writev eth (fixup_checksums frame)
  end

  let connect_uplink config =
    let nat_table = Nat_lookup.empty () in
    let ip = config.Dao.uplink_our_ip in
    Netif.connect "tap0" >>= function
    | `Error (`Unknown msg) -> failwith msg
    | `Error `Disconnected -> failwith "Disconnected"
    | `Error `Unimplemented -> failwith "Unimplemented"
    | `Ok net0 ->
    Eth.connect net0 >>= or_fail "Can't make Ethernet device for tap" >>= fun eth0 ->
    Arp.connect eth0 >>= or_fail "Can't add ARP" >>= fun arp0 ->
    Arp.add_ip arp0 ip >>= fun () ->
    let netvm_mac = Arp.query arp0 config.Dao.uplink_netvm_ip >|= function
      | `Timeout -> failwith "ARP timeout getting MAC of our NetVM"
      | `Ok netvm_mac -> netvm_mac in
    let ip46 = Ipaddr.V4 ip in
    let iface = new netvm_iface eth0 ip46 netvm_mac nat_table in
    let listen router =
      let unnat frame _ip = 
        match Nat_rules.nat ip46 nat_table Nat_rewrite.Destination frame with
        | None ->
            Log.debug "Discarding unexpected frame" Logs.unit;
            return ()
        | Some frame ->
            let frame = fixup_checksums frame |> Cstruct.concat in
            Router.forward_ipv4 router (Cstruct.shift frame Wire_structs.sizeof_ethernet) in
      Netif.listen net0 (fun frame ->
        Eth.input
          ~arpv4:(Arp.input arp0)
          ~ipv4:(unnat frame)
          ~ipv6:(fun _buf -> return ())
          eth0 frame
      ) in
    return (iface, listen)

  let connect qubesDB =
    let config = Dao.read_network_config qubesDB in
    connect_uplink config >>= fun (netvm_iface, netvm_listen) ->
    Dao.set_iptables_error qubesDB "" >>= fun () ->
    Logs.info "Client (internal) network is %a"
      (fun f -> f Ipaddr.V4.Prefix.pp_hum config.Dao.clients_prefix);
    let client_eth = Client_eth.create
      ~client_gw:config.Dao.clients_our_ip
      ~prefix:config.Dao.clients_prefix in
    let router = Router.create
      ~default_gateway:netvm_iface
      ~client_eth in
    Lwt.join [
      Client_net.listen router;
      netvm_listen router
    ]
end
