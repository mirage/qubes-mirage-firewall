(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

(** The link from us to NetVM (and, through that, to the outside world). *)

open Fw_utils

module Make (R: Mirage_random.S)(Clock : Mirage_clock.MCLOCK)(Time : Mirage_time.S) : sig
  type t

  val connect : Dao.network_config -> t Lwt.t
  (** Connect to our NetVM (gateway). *)

  val interface : t option -> interface option
  (** The network interface to NetVM. *)

  val listen : t option -> (unit -> int64) -> (Udp_packet.t * Cstruct.t) Lwt_mvar.t -> Router.t -> unit Lwt.t
  (** Handle incoming frames from NetVM. *)

  val send_dns_client_query: t option -> src_port:int-> dst:Ipaddr.V4.t -> dst_port:int -> Cstruct.t -> (unit, [`Msg of string]) result Lwt.t
end
