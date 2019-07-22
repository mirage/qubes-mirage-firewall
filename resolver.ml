type t = {
  resolver : Dns_resolver.t ref;
  dns_ports : Ports.PortSet.t ref;
  uplink_ip : Ipaddr.V4.t ;
  get_ptime : unit -> Ptime.t;
  get_mtime : unit -> int64;
}

let handle_buf t proto src_port query =
  Dns_resolver.handle_buf !(t.resolver) (t.get_ptime ()) (t.get_mtime ()) true proto t.uplink_ip src_port query

let pick_free_port ~nat_ports ~dns_ports =
  Ports.pick_free_port ~add_list:dns_ports ~consult_list:nat_ports
