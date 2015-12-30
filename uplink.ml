(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt.Infix
open Utils

module Eth = Ethif.Make(Netif)

let src = Logs.Src.create "uplink" ~doc:"Network connection to NetVM"
module Log = (val Logs.src_log src : Logs.LOG)

module Make(Clock : V1.CLOCK) = struct
  module Arp = Arpv4.Make(Eth)(Clock)(OS.Time)
  module IPv4 = Ipv4.Make(Eth)(Arp)

  type t = {
    net : Netif.t;
    eth : Eth.t;
    arp : Arp.t;
    interface : interface;
    my_ip : Ipaddr.t;
    nat_table : Nat_lookup.t;
  }

  class netvm_iface eth my_ip mac nat_table = object
    method my_mac = Eth.mac eth
    method writev ip =
      mac >>= fun dst ->
      let eth_hdr = eth_header_ipv4 ~src:(Eth.mac eth) ~dst in
      match Nat_rules.nat my_ip nat_table Nat_rewrite.Source (Cstruct.concat (eth_hdr :: ip)) with
      | None -> return ()
      | Some frame -> Eth.writev eth (fixup_checksums frame)
  end

  let unnat t router frame _ip =
    match Nat_rules.nat t.my_ip t.nat_table Nat_rewrite.Destination frame with
    | None ->
        Log.debug "Discarding unexpected frame" Logs.unit;
        return ()
    | Some frame ->
        let frame = fixup_checksums frame |> Cstruct.concat in
        Router.forward_ipv4 router (Cstruct.shift frame Wire_structs.sizeof_ethernet)

  let listen t router =
    Netif.listen t.net (fun frame ->
      Eth.input
        ~arpv4:(Arp.input t.arp)
        ~ipv4:(unnat t router frame)
        ~ipv6:(fun _buf -> return ())
        t.eth frame
    )

  let interface t = t.interface

  let connect config =
    let ip = config.Dao.uplink_our_ip in
    Netif.connect "tap0" >>= function
    | `Error (`Unknown msg) -> failwith msg
    | `Error `Disconnected -> failwith "Disconnected"
    | `Error `Unimplemented -> failwith "Unimplemented"
    | `Ok net ->
    Eth.connect net >>= or_fail "Can't make Ethernet device for tap" >>= fun eth ->
    Arp.connect eth >>= or_fail "Can't add ARP" >>= fun arp ->
    Arp.add_ip arp ip >>= fun () ->
    let netvm_mac = Arp.query arp config.Dao.uplink_netvm_ip >|= function
      | `Timeout -> failwith "ARP timeout getting MAC of our NetVM"
      | `Ok netvm_mac -> netvm_mac in
    let my_ip = Ipaddr.V4 ip in
    let nat_table = Nat_lookup.empty () in
    let interface = new netvm_iface eth my_ip netvm_mac nat_table in
    return { net; eth; arp; interface; my_ip; nat_table }
end
