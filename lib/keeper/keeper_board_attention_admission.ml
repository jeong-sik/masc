type token = { owner : unit ref; keys : (string * string) list }
let owners : ((string * string), unit ref) Hashtbl.t = Hashtbl.create 32
let mutex = Stdlib.Mutex.create ()
let reserve_batch ~base_path ~candidate_ids =
  let base_path = Keeper_registry_types.canonical_base_path_exn base_path in
  let owner = ref () in
  let keys = Stdlib.Mutex.protect mutex (fun () ->
    List.filter_map (fun candidate_id ->
      let key = base_path, candidate_id in
      if Hashtbl.mem owners key then None
      else (Hashtbl.add owners key owner; Some key)) candidate_ids)
  in
  { owner; keys }
let owns token candidate_id =
  List.exists (fun (_, held) -> String.equal held candidate_id) token.keys
let blocked ~base_path ~candidate_id =
  let base_path = Keeper_registry_types.canonical_base_path_exn base_path in
  Stdlib.Mutex.protect mutex (fun () -> Hashtbl.mem owners (base_path, candidate_id))
let acquire_singleton ~base_path ~candidate_id =
  let token = reserve_batch ~base_path ~candidate_ids:[candidate_id] in
  match token.keys with [] -> None | _ :: _ -> Some token
let release token =
  Stdlib.Mutex.protect mutex (fun () ->
    List.iter (fun key ->
      match Hashtbl.find_opt owners key with
      | Some owner when owner == token.owner -> Hashtbl.remove owners key
      | Some _ | None -> ()) token.keys)
