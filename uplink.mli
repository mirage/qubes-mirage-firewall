(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** The link from us to NetVM (and, through that, to the outside world). *)

open Fw_utils

module Make (R: Mirage_random.C)(Clock : Mirage_clock_lwt.MCLOCK) : sig
  type t

  val connect : clock:Clock.t -> Dao.network_config -> t Lwt.t
  (** Connect to our NetVM (gateway). *)

  val interface : t -> interface
  (** The network interface to NetVM. *)

  val listen : t -> My_dns_client.Dns_client.t -> Cstruct.t Lwt_mvar.t -> Router.t -> unit Lwt.t
  (** Handle incoming frames from NetVM. *)

  val send_dns_response: t -> int -> (Dns.proto * Ipaddr.V4.t * int * Cstruct.t) -> unit Lwt.t
  val send_dns_query: t -> int -> (Dns.proto * Ipaddr.V4.t * Cstruct.t) -> unit Lwt.t
  val send_dns_client_query: t -> src_port:int-> dst:Ipaddr.V4.t -> dst_port:int -> Cstruct.t -> (unit, [`Msg of string]) result Lwt.t

end
