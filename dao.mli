(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** Wrapper for XenStore and QubesDB databases. *)

module ClientVif : sig
  type t = {
    domid : int;
    device_id : int;
  }
  val pp : t Fmt.t
end
module VifMap : sig
  include Map.S with type key = ClientVif.t
  val find : key -> 'a t -> 'a option
end

val watch_clients : (Ipaddr.V4.t VifMap.t -> unit) -> 'a Lwt.t
(** [watch_clients fn] calls [fn clients] with the list of backend clients
    in XenStore, and again each time XenStore updates. *)

type network_config = {
  uplink_netvm_ip : Ipaddr.V4.t;      (* The IP address of NetVM (our gateway) *)
  uplink_our_ip : Ipaddr.V4.t;        (* The IP address of our interface to NetVM *)

  clients_our_ip : Ipaddr.V4.t;        (* The IP address of our interface to our client VMs (their gateway) *)
}

val read_network_config : Qubes.DB.t -> network_config

val set_iptables_error : Qubes.DB.t -> string -> unit Lwt.t
