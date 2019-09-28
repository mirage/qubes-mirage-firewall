open Lwt.Infix

module Dns_transport_qubes = struct
  type +'a io = 'a Lwt.t
  type io_addr = Ipaddr.V4.t * int
  type ns_addr = [ `TCP | `UDP ] * io_addr
  type stack = (src_port:int -> dst:Ipaddr.V4.t -> dst_port:int -> Cstruct.t -> (unit, [ `Msg of string ]) result Lwt.t) * Cstruct.t Lwt_mvar.t

  type t = {
    rng : (int -> Cstruct.t) ;
    nameserver : ns_addr ;
    stack : stack ;
  }
  type flow = t

  let nameserver t = t.nameserver
  let rng t = t.rng

  let create ?rng ?(nameserver = `UDP, (Ipaddr.V4.of_string_exn "91.239.100.100", 53)) stack =
    let rng = match rng with None -> assert false | Some rng -> rng in
    { rng ; nameserver ; stack }

  let connect ?nameserver t = Lwt.return (Ok t)

  let send (t : flow) buf : (unit, [> `Msg of string ]) result Lwt.t =
    let dst, dst_port = snd t.nameserver in
    (fst t.stack) ~src_port:1053 ~dst ~dst_port buf >|= Rresult.R.open_error_msg

  let recv t =
    Lwt_mvar.take (snd t.stack) >|= fun buf -> Ok buf

  let close _ = Lwt.return_unit

  let bind = Lwt.bind

  let lift = Lwt.return
end

module Dns_client = Dns_client.Make(Dns_transport_qubes)


