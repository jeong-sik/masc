type 'snapshot observation = Missing | Unavailable of string | Available of 'snapshot
type keeper =
  { keeper_id : string
  ; ordinary : Keeper_memory_os_current.t observation
  ; source_bound : Keeper_memory_source_current.t observation
  }
type t =
  { observed_at : float
  ; keepers : keeper list
  ; identity : string
  }

let ( let* ) = Result.bind

let rec canonical = function
  | `Assoc fields -> `Assoc (List.map (fun (key, value) -> key, canonical value) fields
      |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List values -> `List (List.map canonical values)
  | value -> value

let hash value = Digestif.SHA256.(digest_string (Yojson.Safe.to_string (canonical value)) |> to_hex)
let observation_json snapshot_json = function
  | Missing -> `Assoc ["status", `String "missing"]
  | Unavailable detail -> `Assoc ["status", `String "unavailable"; "detail", `String detail]
  | Available snapshot -> `Assoc ["status", `String "available"; "snapshot", snapshot_json snapshot]

let keeper_json keeper = `Assoc
  [ "keeper_id", `String keeper.keeper_id
  ; "ordinary", observation_json Keeper_memory_os_current.to_json keeper.ordinary
  ; "source_bound", observation_json Keeper_memory_source_current.to_json keeper.source_bound ]

let read_snapshot path read =
  try
    match Unix.stat path with
    | { Unix.st_kind = Unix.S_REG; _ } ->
      (try match read () with
       | Ok (Some snapshot) -> Available snapshot
       | Ok None -> Unavailable (path ^ ": snapshot became unavailable during read")
       | Error detail -> Unavailable detail
       with
       | Unix.Unix_error (error, operation, failed_path) ->
         Unavailable (Printf.sprintf "%s: %s: %s" operation failed_path (Unix.error_message error))
       | Sys_error detail -> Unavailable detail)
    | _ -> Unavailable (path ^ ": snapshot is not a regular file")
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Missing
  | Unix.Unix_error (error, operation, path) ->
    Unavailable (Printf.sprintf "%s: %s: %s" operation path (Unix.error_message error))
  | Sys_error detail -> Unavailable detail

let discover ~keepers_dir =
  let failure error operation path =
    Printf.sprintf "%s: %s: %s" operation path (Unix.error_message error)
  in
  try
    match Unix.stat keepers_dir with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      (* Enumerate once, after observing a real directory. A vanished or
         unreadable directory is a failed inventory, never a fresh empty one. *)
      (try
         let files = Sys.readdir keepers_dir |> Array.to_list in
         let configured = List.filter_map (fun file ->
           match Filename.chop_suffix_opt ~suffix:".toml" file with
           | None -> None
           | Some basename ->
             Some (match Keeper_types_profile.load_keeper_toml (Filename.concat keepers_dir file) with
               | Ok (keeper_name, _) -> keeper_name
               | Error _ -> basename)) files in
         let ids = List.sort_uniq String.compare
           (configured
            @ List.filter_map Keeper_memory_os_current.keeper_id_of_filename files
            @ List.filter_map Keeper_memory_source_current.keeper_id_of_filename files) in
         if List.exists (fun id -> String.trim id = "") ids
         then Error "Keeper inventory contains a blank identity"
         else Ok ids
       with
       | Unix.Unix_error (error, operation, path) -> Error (failure error operation path)
       | Sys_error detail -> Error detail)
    | _ -> Error "Keeper memory directory is not a directory"
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
    Error ("Keeper memory directory is missing: " ^ keepers_dir)
  | Unix.Unix_error (error, operation, path) -> Error (failure error operation path)
  | Sys_error detail -> Error detail

let read_keeper ~keepers_dir keeper_id =
  { keeper_id
  ; ordinary = read_snapshot
      (Keeper_memory_os_current.path_for_keepers_dir ~keepers_dir ~keeper_id)
      (fun () -> Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id)
  ; source_bound = read_snapshot
      (Keeper_memory_source_current.path_for_keepers_dir ~keepers_dir ~keeper_id)
      (fun () -> Keeper_memory_source_current.read_for_keepers_dir ~keepers_dir ~keeper_id)
  }

let collect ~base_path =
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let* ids = discover ~keepers_dir in
  let keepers = List.map (read_keeper ~keepers_dir) ids in
  Ok { observed_at = Time_compat.now (); keepers;
       identity = hash (`List (List.map keeper_json keepers)) }

let keepers t = t.keepers
let fingerprint t = t.identity
let http_json ~base_path =
  let captured = collect ~base_path in
  let observed_at = match captured with Ok t -> t.observed_at | Error _ -> Time_compat.now () in
  `Assoc (["schema", `String "workspace.memory.context.v1"; "generated_at", `Float observed_at;
    "source_validation", `String "stored_bindings_not_revalidated";
    "consistency", `String "individual_store_snapshots"] @ match captured with
    | Ok t -> ["discovery", `Assoc ["status", `String "available"];
               "keepers", `List (List.map keeper_json t.keepers)]
    | Error detail -> ["discovery", `Assoc ["status", `String "unavailable"; "detail", `String detail];
                      "keepers", `List []])
