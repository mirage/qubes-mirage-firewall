(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Wrapper for XenStore and QubesDB databases. *)

open Utils

type client_vif = {
  domid : int;
  device_id : int;
  client_ip : Ipaddr.V4.t;
}

val watch_clients : (IntSet.t -> unit) -> 'a Lwt.t
(** [watch_clients fn] calls [fn clients] with the current set of backend client domain IDs
    in XenStore, and again each time the set changes. *)

val client_vifs : int -> client_vif list Lwt.t
(** [client_vif domid] is the list of network interfaces to the client VM [domid]. *)

type network_config = {
  uplink_netvm_ip : Ipaddr.V4.t;      (* The IP address of NetVM (our gateway) *)
  uplink_our_ip : Ipaddr.V4.t;        (* The IP address of our interface to NetVM *)

  clients_our_ip : Ipaddr.V4.t;        (* The IP address of our interface to our client VMs (their gateway) *)
}

val read_network_config : Qubes.DB.t -> network_config

val set_iptables_error : Qubes.DB.t -> string -> unit Lwt.t
