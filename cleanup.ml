(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

type t = (unit -> unit) list ref

let create () = ref []
let on_cleanup t fn = t := fn :: !t

let cleanup t =
  let tasks = !t in
  t := [];
  List.iter (fun f -> f ()) tasks
