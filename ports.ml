module Port = struct
  type t = int
  let compare a b = compare a b
end
module PortSet = Set.Make(Port)

(* TODO put retries in here *)
let rec pick_free_port ~add_list ~consult_list =
  let p = 1024 + Random.int (0xffff - 1024) in
  if PortSet.(mem p add_list || mem p consult_list)
  then pick_free_port ~add_list ~consult_list
  else
    begin
      PortSet.add p add_list, p;
    end
