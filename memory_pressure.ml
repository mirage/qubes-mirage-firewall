(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt

let src = Logs.Src.create "memory_pressure" ~doc:"Memory pressure monitor"
module Log = (val Logs.src_log src : Logs.LOG)

let wordsize_in_bytes = Sys.word_size / 8

let fraction_free stats =
  let { OS.Memory.free_words; heap_words; _ } = stats in
  float free_words /. float heap_words

let meminfo stats =
  let { OS.Memory.free_words; heap_words; _ } = stats in
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
      let rec aux () =
        OS.Xs.make () >>= fun xs ->
        OS.Xs.immediate xs (fun h ->
            OS.Xs.write h "memory/meminfo" (meminfo stats)
          ) >>= fun () ->
        OS.Time.sleep_ns (Duration.of_f 600.0) >>= fun () ->
        aux ()
      in
      aux ()
  )

let init () =
  Gc.full_major ();
  let stats = OS.Memory.quick_stat () in
  report_mem_usage stats

let status () =
  let stats = OS.Memory.quick_stat () in
  if fraction_free stats > 0.1 then `Ok
  else (
    Gc.full_major ();
    let stats = OS.Memory.quick_stat () in
    report_mem_usage stats;
    if fraction_free stats < 0.1 then `Memory_critical
    else `Ok
  )
