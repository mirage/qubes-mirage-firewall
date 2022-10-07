open Lwt.Infix

module Transport (R : Mirage_random.S) (C : Mirage_clock.MCLOCK) (Time : Mirage_time.S) = struct
  type +'a io = 'a Lwt.t
  type io_addr = Ipaddr.V4.t * int
  type stack = Router.t * (src_port:int -> dst:Ipaddr.V4.t -> dst_port:int -> Cstruct.t -> (unit, [ `Msg of string ]) result Lwt.t) * (Udp_packet.t * Cstruct.t) Lwt_mvar.t

  type t = {
    protocol : Dns.proto ;
    nameserver : io_addr ;
    stack : stack ;
    timeout_ns : int64 ;
  }
  type context = t

  let nameservers { protocol ; nameserver ; _ } = protocol, [ nameserver ]
  let rng = R.generate ?g:None
  let clock = C.elapsed_ns

  let create ?nameservers ~timeout stack =
    let protocol, nameserver = match nameservers with
      | None | Some (_, []) -> invalid_arg "no nameserver found"
      | Some (proto, ns :: _) -> proto, ns
    in
    { protocol ; nameserver ; stack ; timeout_ns = timeout }

  let with_timeout timeout_ns f =
    let timeout = Time.sleep_ns timeout_ns >|= fun () -> Error (`Msg "DNS request timeout") in
    Lwt.pick [ f ; timeout ]

  let connect (t : t) = Lwt.return (Ok t)

  let send_recv (ctx : context) buf : (Cstruct.t, [> `Msg of string ]) result Lwt.t =
    let open Router in
    let open My_nat in
    let dst, dst_port = ctx.nameserver in
    let router, send_udp, answer = ctx.stack in
    let src_port = My_nat.free_udp_port router.nat ~src:router.uplink#my_ip ~dst ~dst_port:53 in
    with_timeout ctx.timeout_ns
      ((send_udp ~src_port ~dst ~dst_port buf >|= Rresult.R.open_error_msg) >>= function
        | Ok () -> (Lwt_mvar.take answer >|= fun (_, dns_response) -> Ok dns_response)
        | Error _ as e -> Lwt.return e) >|= fun result ->
    router.nat.udp_dns <- List.filter (fun p -> p <> src_port) router.nat.udp_dns;
    result

  let close _ = Lwt.return_unit

  let bind = Lwt.bind

  let lift = Lwt.return
end

