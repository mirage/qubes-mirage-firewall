open Mirage

let client =
  foreign
    "Unikernel.Client" @@ time @-> console @-> stackv4 @-> job

let () =
  let stack = generic_stackv4 default_network in
  let job =  [ client $ default_time $ default_console $ stack ] in
  register "http-fetch" job
