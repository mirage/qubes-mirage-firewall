(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt

let src = Logs.Src.create "memory_pressure" ~doc:"Memory pressure monitor"
module Log = (val Logs.src_log src : Logs.LOG)

let wordsize_in_bytes = Sys.word_size / 8

let fraction_free stats =
  let { Xen_os.Memory.free_words; heap_words; _ } = stats in
  float free_words /. float heap_words

let meminfo stats =
  let { Xen_os.Memory.free_words; heap_words; _ } = stats in
  let mem_total = heap_words * wordsize_in_bytes in
  let mem_free = free_words * wordsize_in_bytes in
  Log.info (fun f -> f "Writing meminfo: free %a / %a (%.2f %%)"
    Fmt.bi_byte_size mem_free
    Fmt.bi_byte_size mem_total
    (fraction_free stats *. 100.0));
  Printf.sprintf "MemTotal: %d kB\n\
                  MemFree: %d kB\n\
                  Buffers: 0 kB\n\
                  Cached: 0 kB\n\
                  SwapTotal: 0 kB\n\
                  SwapFree: 0 kB\n" (mem_total / 1024) (mem_free / 1024)

let report_mem_usage stats =
  Lwt.async (fun () ->
    let open Xen_os in
    Xs.make () >>= fun xs ->
    Xs.immediate xs (fun h ->
      Xs.write h "memory/meminfo" (meminfo stats)
    )
  )

let init () =
  Gc.full_major ();
  let stats = Xen_os.Memory.quick_stat () in
  report_mem_usage stats

let status () =
  let stats = Xen_os.Memory.quick_stat () in
  if fraction_free stats > 0.4 then `Ok
  else (
    Gc.full_major ();
    Xen_os.Memory.trim ();
    let stats = Xen_os.Memory.quick_stat () in
    report_mem_usage stats;
    if fraction_free stats < 0.4 then `Memory_critical
    else `Ok
  )
