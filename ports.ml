module Set = Set.Make(struct
  type t = int
  let compare a b = compare a b
end)

include Set

let rec pick_free_port ?(retries = 10) ~consult add_to =
  let p = 1024 + Random.int (0xffff - 1024) in
  if (mem p !consult || mem p !add_to) && retries <> 0
  then pick_free_port ~retries:(retries - 1) ~consult add_to
  else
    begin
      add_to := add p !add_to;
      p
    end
