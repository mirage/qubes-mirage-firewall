(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

open Lwt

let src = Logs.Src.create "memory_pressure" ~doc:"Memory pressure monitor"
module Log = (val Logs.src_log src : Logs.LOG)

let total_pages = Os_xen.MM.Heap_pages.total ()
let pagesize_kb = Io_page.page_size / 1024

let meminfo ~used =
  let mem_total = total_pages * pagesize_kb in
  let mem_free = (total_pages - used) * pagesize_kb in
  Log.info (fun f -> f "Writing meminfo: free %d / %d kB (%.2f %%)"
    mem_free mem_total (float_of_int mem_free /. float_of_int mem_total *. 100.0));
  Printf.sprintf "MemTotal: %d kB\n\
                  MemFree: %d kB\n\
                  Buffers: 0 kB\n\
                  Cached: 0 kB\n\
                  SwapTotal: 0 kB\n\
                  SwapFree: 0 kB\n" mem_total mem_free

let report_mem_usage used =
  Lwt.async (fun () ->
    let open Os_xen in
    Xs.make () >>= fun xs ->
    Xs.immediate xs (fun h ->
      Xs.write h "memory/meminfo" (meminfo ~used)
    )
  )

let init () =
  Gc.full_major ();
  let used = Os_xen.MM.Heap_pages.used () in
  report_mem_usage used

let status () =
  let used = Os_xen.MM.Heap_pages.used () |> float_of_int in
  let frac = used /. float_of_int total_pages in
  if frac < 0.9 then `Ok
  else (
    Gc.full_major ();
    let used = Os_xen.MM.Heap_pages.used () in
    report_mem_usage used;
    let frac = float_of_int used /. float_of_int total_pages in
    if frac > 0.9 then `Memory_critical
    else `Ok
  )
