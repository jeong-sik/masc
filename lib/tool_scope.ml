type scope =
  | Surface
  | Agent_internal

let agent_internal_list : string list = []

let agent_internal_names () = agent_internal_list

let agent_internal_set : (string, unit) Hashtbl.t =
  let table = Hashtbl.create (List.length agent_internal_list * 2) in
  List.iter (fun name -> Hashtbl.replace table name ()) agent_internal_list;
  table
;;

let classify ~name =
  if Hashtbl.mem agent_internal_set name then Agent_internal else Surface
;;

let scope_to_string = function
  | Surface -> "surface"
  | Agent_internal -> "agent_internal"
;;
