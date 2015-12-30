(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Utils

let src = Logs.Src.create "router" ~doc:"Router"
module Log = (val Logs.src_log src : Logs.LOG)

type t = {
  client_net : Client_net.t;
  default_gateway : interface;
}

let create ~client_net ~default_gateway = { client_net; default_gateway }

let client_net t = t.client_net

let target t buf =
  let open Wire_structs.Ipv4_wire in
  let dst_ip = get_ipv4_dst buf |> Ipaddr.V4.of_int32 in
  Log.debug "Got IPv4: dst=%s" (fun f -> f (Ipaddr.V4.to_string dst_ip));
  if Ipaddr.V4.Prefix.mem dst_ip (Client_net.prefix t.client_net) then (
    match Client_net.lookup t.client_net dst_ip with
    | Some client_link -> Some (client_link :> interface)
    | None ->
      Log.warn "Packet to unknown internal client %a - dropping"
        (fun f -> f Ipaddr.V4.pp_hum dst_ip);
      None
  ) else Some t.default_gateway

let add_client t = Client_net.add_client t.client_net
let remove_client t = Client_net.remove_client t.client_net
