open Lwt.Infix

  type +'a io = 'a Lwt.t
  type io_addr = Ipaddr.V4.t * int
  type stack = Dispatcher.t *
               (src_port:int -> dst:Ipaddr.V4.t -> dst_port:int -> string -> (unit, [ `Msg of string ]) result Lwt.t) *
               (Udp_packet.t * string) Lwt_mvar.t

  module IM = Map.Make(Int)

  type t = {
    protocol : Dns.proto ;
    nameserver : io_addr ;
    stack : stack ;
    timeout_ns : int64 ;
    mutable requests : string Lwt_condition.t IM.t ;
  }
  type context = t

  let nameservers { protocol ; nameserver ; _ } = protocol, [ nameserver ]
  let rng = Mirage_crypto_rng.generate ?g:None
  let clock = Mirage_mtime.elapsed_ns

  let rec read t =
    let _, _, answer = t.stack in
    Lwt_mvar.take answer >>= fun (_, data) ->
    if String.length data > 2 then begin
      match IM.find_opt (String.get_uint16_be data 0) t.requests with
      | Some cond -> Lwt_condition.broadcast cond data
      | None -> ()
    end;
    read t

  let create ?nameservers ~timeout stack =
    let protocol, nameserver = match nameservers with
      | None | Some (_, []) -> invalid_arg "no nameserver found"
      | Some (proto, ns :: _) -> proto, ns
    in
    let t =
      { protocol ; nameserver ; stack ; timeout_ns = timeout ; requests = IM.empty }
    in
    Lwt.async (fun () -> read t);
    t

  let with_timeout timeout_ns f =
    let timeout = Mirage_sleep.ns timeout_ns >|= fun () -> Error (`Msg "DNS request timeout") in
    Lwt.pick [ f ; timeout ]

  let connect (t : t) = Lwt.return (Ok (t.protocol, t))

  let send_recv (ctx : context) buf : (string, [> `Msg of string ]) result Lwt.t =
    let dst, dst_port = ctx.nameserver in
    let router, send_udp, _ = ctx.stack in
    let src_port, evict =
      My_nat.free_udp_port router.nat ~src:router.config.our_ip ~dst ~dst_port:53
    in
    let id = String.get_uint16_be buf 0 in
    with_timeout ctx.timeout_ns
      (let cond = Lwt_condition.create () in
       ctx.requests <- IM.add id cond ctx.requests;
       (send_udp ~src_port ~dst ~dst_port buf >|= Rresult.R.open_error_msg) >>= function
       | Ok () -> Lwt_condition.wait cond >|= fun dns_response -> Ok dns_response
       | Error _ as e -> Lwt.return e) >|= fun result ->
    ctx.requests <- IM.remove id ctx.requests;
    evict ();
    result

  let close _ = Lwt.return_unit

  let bind = Lwt.bind

  let lift = Lwt.return
