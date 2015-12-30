(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Utils

let src = Logs.Src.create "router" ~doc:"Router"
module Log = (val Logs.src_log src : Logs.LOG)

type t = {
  client_eth : Client_eth.t;
  default_gateway : interface;
}

let create ~client_eth ~default_gateway = { client_eth; default_gateway }

let client_eth t = t.client_eth

let target t buf =
  let open Wire_structs.Ipv4_wire in
  let dst_ip = get_ipv4_dst buf |> Ipaddr.V4.of_int32 in
  Log.debug "Got IPv4: dst=%s" (fun f -> f (Ipaddr.V4.to_string dst_ip));
  if Ipaddr.V4.Prefix.mem dst_ip (Client_eth.prefix t.client_eth) then (
    match Client_eth.lookup t.client_eth dst_ip with
    | Some client_link -> Some (client_link :> interface)
    | None ->
      Log.warn "Packet to unknown internal client %a - dropping"
        (fun f -> f Ipaddr.V4.pp_hum dst_ip);
      None
  ) else Some t.default_gateway

let add_client t = Client_eth.add_client t.client_eth
let remove_client t = Client_eth.remove_client t.client_eth

let forward_ipv4 router buf =
  match Memory_pressure.status () with
  | `Memory_critical -> (* TODO: should happen before copying and async *)
      print_endline "Memory low - dropping packet";
      return ()
  | `Ok ->
  match target router buf with
  | Some iface -> iface#writev [buf]
  | None -> return ()
