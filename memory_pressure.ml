(* Copyright (C) 2015, Thomas Leonard <thomas.leonard@unikernel.com>
   See the README file for details. *)

let total_pages = OS.MM.Heap_pages.total () |> float_of_int

let status () =
  let used = OS.MM.Heap_pages.used () |> float_of_int in
  let frac = used /. total_pages in
  if frac < 0.9 then `Ok
  else (
    Gc.full_major ();
    let used = OS.MM.Heap_pages.used () |> float_of_int in
    let frac = used /. total_pages in
    if frac > 0.9 then `Memory_critical
    else `Ok
  )
