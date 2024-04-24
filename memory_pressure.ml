(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

let src = Logs.Src.create "memory_pressure" ~doc:"Memory pressure monitor"
module Log = (val Logs.src_log src : Logs.LOG)

let fraction_free stats =
  let { Xen_os.Memory.free_words; heap_words; _ } = stats in
  float free_words /. float heap_words

let init () =
  Gc.full_major ()

let status () =
  let stats = Xen_os.Memory.quick_stat () in
  if fraction_free stats > 0.5 then `Ok
  else (
    Gc.full_major ();
    Xen_os.Memory.trim ();
    let stats = Xen_os.Memory.quick_stat () in
    if fraction_free stats < 0.6 then `Memory_critical
    else `Ok
  )
