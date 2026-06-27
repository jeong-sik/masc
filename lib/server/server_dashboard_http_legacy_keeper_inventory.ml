(** Legacy keeper-store inventory dashboard helper.

    Current Memory OS fact stores live under [.masc/config/keepers]. Older
    runtime data under [.masc/keepers] can still contain live runtime stores,
    migrated memory artifacts, backups, and orphaned temp files. This helper is
    intentionally read-only: it classifies a bounded scan and emits a dry-run
    cleanup plan with operator approval required. *)

type inventory_class =
  | Live
  | Migrated
  | Orphaned
  | Backup
  | Unknown

type entry =
  { path : string
  ; depth : int
  ; kind : string
  ; bytes : int
  ; classification : inventory_class
  ; reason : string
  }

type scan_error =
  { path : string
  ; operation : string
  ; message : string
  }

type scan_result =
  { entries : entry list
  ; truncated : bool
  ; visited : int
  ; errors : scan_error list
  ; exists : bool
  }

let default_max_depth = 4
let default_max_entries = 5_000

let class_to_string = function
  | Live -> "live"
  | Migrated -> "migrated"
  | Orphaned -> "orphaned"
  | Backup -> "backup"
  | Unknown -> "unknown"
;;

let normalize_path path =
  path
  |> Env_config_core.normalize_path_lexically
  |> Env_config_core.strip_path_trailing_slashes
;;

let path_components_under_root ~root path =
  let root = normalize_path root in
  let path = normalize_path path in
  let rec loop acc current =
    if String.equal current root
    then Some acc
    else (
      let parent = Filename.dirname current in
      if String.equal parent current
      then None
      else loop (Filename.basename current :: acc) parent)
  in
  loop [] path
;;

let path_of_components = function
  | [] -> "."
  | first :: rest -> List.fold_left Filename.concat first rest
;;

let relative_path ~root path =
  match path_components_under_root ~root path with
  | Some parts -> path_of_components parts
  | None -> path
;;

let is_runtime_store_dir name =
  Option.is_some (Config_dir_resolver.keeper_runtime_store_of_dirname name)
;;

let regular_path_exists_no_follow path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_REG -> true
    | Unix.S_DIR | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
      false
  with
  | Unix.Unix_error _ -> false
;;

let migrated_memory_path_for_legacy_filename ~current_keepers_dir ~keeper_id filename =
  if String.equal filename "facts.jsonl"
  then
    Some
      (Keeper_memory_os_io.facts_path_for_keepers_dir
         ~keepers_dir:current_keepers_dir
         ~keeper_id)
  else if String.equal filename "events.jsonl"
  then
    Some
      (Keeper_memory_os_io.events_path_for_keepers_dir
         ~keepers_dir:current_keepers_dir
         ~keeper_id)
  else None
;;

let migrated_memory_path_exists ~current_keepers_dir parts =
  match parts with
  | keeper_id :: filename :: [] ->
    (match migrated_memory_path_for_legacy_filename ~current_keepers_dir ~keeper_id filename with
     | Some path -> regular_path_exists_no_follow path
     | None -> false)
  | _ -> false
;;

let classify ~current_keepers_dir ~parts ~kind =
  if migrated_memory_path_exists ~current_keepers_dir parts
  then Migrated, "memory_os_file_already_present_under_config_keepers"
  else (
    match parts with
    | [ top ] when String.equal kind "file" && Keeper_meta_store.is_keeper_meta_file top ->
      Live, "legacy_keeper_meta_json"
    | top :: _ when is_runtime_store_dir top ->
      Live, "known_top_level_runtime_store"
    | _keeper :: child :: _ when is_runtime_store_dir child ->
      Live, "known_keeper_runtime_store"
    | _ -> Unknown, "unclassified_legacy_path")
;;

let stat_kind st =
  match st.Unix.st_kind with
  | Unix.S_REG -> "file"
  | Unix.S_DIR -> "dir"
  | Unix.S_LNK -> "symlink"
  | Unix.S_CHR -> "char"
  | Unix.S_BLK -> "block"
  | Unix.S_FIFO -> "fifo"
  | Unix.S_SOCK -> "socket"
;;

let error_message = function
  | Unix.Unix_error (err, _, _) -> Unix.error_message err
  | Sys_error msg -> msg
  | Invalid_argument _ -> "invalid_argument"
  | Failure _ -> "failure"
  | _ -> "unexpected_exception"
;;

let display_path ~root path =
  if String.equal path root then "." else relative_path ~root path
;;

let record_error errors ~root ~operation path exn =
  let error =
    { path = display_path ~root path; operation; message = error_message exn }
  in
  errors := error :: !errors;
  Log.Dashboard.warn
    "legacy keeper inventory %s failed for %s: %s"
    operation
    error.path
    error.message
;;

let record_scan_error errors ~operation ~path ~message =
  errors := { path; operation; message } :: !errors;
  Log.Dashboard.warn
    "legacy keeper inventory %s failed for %s: %s"
    operation
    path
    message
;;

let lstat_result errors ~root path =
  try Ok (Unix.lstat path) with
  | Unix.Unix_error _ as exn ->
    record_error errors ~root ~operation:"lstat" path exn;
    Error ()
;;

let sorted_readdir_result errors ~root path =
  try Ok (Sys.readdir path |> Array.to_list |> List.sort String.compare) with
  | Sys_error _ as exn ->
    record_error errors ~root ~operation:"readdir" path exn;
    Error ()
;;

let scan_entries ~legacy_dir ~current_keepers_dir ~max_depth ~max_entries =
  let entries = ref [] in
  let visited = ref 0 in
  let truncated = ref false in
  let errors = ref [] in
  let rec visit ~depth path =
    if !visited >= max_entries
    then truncated := true
    else (
      match lstat_result errors ~root:legacy_dir path with
      | Error () -> ()
      | Ok st ->
        incr visited;
        let kind = stat_kind st in
        (match path_components_under_root ~root:legacy_dir path with
         | None ->
           record_scan_error
             errors
             ~operation:"relative_path"
             ~path:"<outside-legacy-root>"
             ~message:"visited path is not under legacy keeper root"
         | Some parts ->
           let rel = path_of_components parts in
           let classification, reason = classify ~current_keepers_dir ~parts ~kind in
           entries
           := { path = rel
              ; depth
              ; kind
              ; bytes = st.Unix.st_size
              ; classification
              ; reason
              }
              :: !entries;
           if String.equal kind "dir" && depth < max_depth
           then (
             match sorted_readdir_result errors ~root:legacy_dir path with
             | Error () -> ()
             | Ok names ->
               names
               |> List.iter (fun name ->
                 visit ~depth:(depth + 1) (Filename.concat path name)))))
  in
  let exists =
    match
      try Ok (Unix.lstat legacy_dir) with
      | Unix.Unix_error (Unix.ENOENT, _, _)
      | Unix.Unix_error (Unix.ENOTDIR, _, _) -> Error `Missing
      | Unix.Unix_error _ as exn -> Error (`Failure exn)
    with
    | Error `Missing -> false
    | Error (`Failure exn) ->
      record_error errors ~root:legacy_dir ~operation:"lstat" legacy_dir exn;
      false
    | Ok st when st.Unix.st_kind = Unix.S_DIR ->
      (match sorted_readdir_result errors ~root:legacy_dir legacy_dir with
       | Error () -> true
       | Ok names ->
         names |> List.iter (fun name -> visit ~depth:0 (Filename.concat legacy_dir name));
         true)
    | Ok st ->
      record_error
        errors
        ~root:legacy_dir
        ~operation:"readdir"
        legacy_dir
        (Sys_error
           (Printf.sprintf "expected directory, found %s" (stat_kind st)));
      true
  in
  { entries = List.rev !entries
  ; truncated = !truncated
  ; visited = !visited
  ; errors = List.rev !errors
  ; exists
  }
;;

let entry_to_json (entry : entry) =
  `Assoc
    [ "path", `String entry.path
    ; "depth", `Int entry.depth
    ; "kind", `String entry.kind
    ; "bytes", `Int entry.bytes
    ; "class", `String (class_to_string entry.classification)
    ; "reason", `String entry.reason
    ]
;;

let scan_error_to_json (error : scan_error) =
  `Assoc
    [ "path", `String error.path
    ; "operation", `String error.operation
    ; "message", `String error.message
    ]
;;

let class_totals entries =
  let classes = [ Live; Migrated; Orphaned; Backup; Unknown ] in
  classes
  |> List.map (fun cls ->
    let count, bytes =
      List.fold_left
        (fun (count, bytes) entry ->
           if entry.classification = cls
           then count + 1, bytes + entry.bytes
           else count, bytes)
        (0, 0)
        entries
    in
    class_to_string cls, `Assoc [ "count", `Int count; "bytes", `Int bytes ])
;;

let cleanup_plan_json () =
  `Assoc
    [ "delete_allowed", `Bool false
    ; "requires_operator_approval", `Bool true
    ; "candidate_policy", `String "disabled_until_owner_verified"
    ; "candidate_classes", `List []
    ; "candidate_count", `Int 0
    ; "candidate_bytes", `Int 0
    ; "candidates", `List []
    ]
;;

let redacted_workspace_path ~base_path path =
  match path_components_under_root ~root:base_path path with
  | Some parts -> path_of_components parts
  | None ->
    if String.equal (Filename.basename path) Common.keepers_runtime_dirname
    then Filename.concat "<config>" Common.keepers_runtime_dirname
    else "<external>"
;;

let legacy_keeper_inventory_http_json ~base_path ?(max_depth = default_max_depth)
      ?(max_entries = default_max_entries) () =
  let legacy_dir = Common.keepers_runtime_dir_of_base ~base_path in
  let current_keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let result =
    scan_entries ~legacy_dir ~current_keepers_dir ~max_depth ~max_entries
  in
  `Assoc
    [ "path_scope", `String "workspace_relative"
    ; "legacy_keepers_path", `String (redacted_workspace_path ~base_path legacy_dir)
    ; ( "current_config_keepers_path"
      , `String (redacted_workspace_path ~base_path current_keepers_dir) )
    ; "exists", `Bool result.exists
    ; "read_only", `Bool true
    ; "max_depth", `Int max_depth
    ; "max_entries", `Int max_entries
    ; "visited_entries", `Int result.visited
    ; "truncated", `Bool result.truncated
    ; "scan_complete", `Bool ((not result.truncated) && result.errors = [])
    ; "scan_errors", `List (List.map scan_error_to_json result.errors)
    ; "class_totals", `Assoc (class_totals result.entries)
    ; "entries", `List (List.map entry_to_json result.entries)
    ; "dry_run_cleanup_plan", cleanup_plan_json ()
    ]
;;
