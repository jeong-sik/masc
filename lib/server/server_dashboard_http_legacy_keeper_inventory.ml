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

let default_max_depth = 4
let default_max_entries = 5_000

let class_to_string = function
  | Live -> "live"
  | Migrated -> "migrated"
  | Orphaned -> "orphaned"
  | Backup -> "backup"
  | Unknown -> "unknown"
;;

let relative_path ~root path =
  let root_prefix = if String.ends_with ~suffix:"/" root then root else root ^ "/" in
  if String.starts_with ~prefix:root_prefix path
  then String.sub path (String.length root_prefix) (String.length path - String.length root_prefix)
  else path
;;

let split_relative rel =
  rel
  |> String.split_on_char '/'
  |> List.filter (fun part -> not (String.equal part ""))
;;

let has_suffix name suffix = String.ends_with ~suffix name

let is_backup_name name =
  has_suffix name ".bak"
  || has_suffix name ".backup"
  || has_suffix name ".old"
  || has_suffix name "~"
;;

let is_orphan_temp_name name =
  String.equal name "PYEOF"
  || (String.starts_with ~prefix:".atomic_" name && has_suffix name ".tmp")
  || has_suffix name ".tmp"
;;

let live_top_level_dirs =
  [ "tool_usage"
  ; "runtime-manifests"
  ; "metrics"
  ; "execution-receipts"
  ; "turn-records"
  ; "reaction-ledger"
  ; "trajectories"
  ]
;;

let live_keeper_child_dirs =
  [ "metrics"
  ; "execution-receipts"
  ; "turn-records"
  ; "reaction-ledger"
  ; "runtime-manifests"
  ; "trajectories"
  ; "tool_usage"
  ]
;;

let memory_os_filenames = [ "facts.jsonl"; "events.jsonl"; "episodes.jsonl" ]

let member name names = List.exists (String.equal name) names

let migrated_memory_path_exists ~current_keepers_dir parts =
  match parts with
  | keeper_id :: filename :: [] when member filename memory_os_filenames ->
    Sys.file_exists (Filename.concat (Filename.concat current_keepers_dir keeper_id) filename)
  | _ -> false
;;

let classify ~current_keepers_dir ~rel ~kind =
  let parts = split_relative rel in
  let name =
    match List.rev parts with
    | [] -> rel
    | hd :: _ -> hd
  in
  if is_orphan_temp_name name
  then Orphaned, "orphaned_temp_or_marker"
  else if is_backup_name name
  then Backup, "backup_suffix"
  else if migrated_memory_path_exists ~current_keepers_dir parts
  then Migrated, "memory_os_file_already_present_under_config_keepers"
  else (
    match parts with
    | [ top ] when String.equal kind "file" && has_suffix top ".json" ->
      Live, "legacy_keeper_meta_json"
    | top :: _ when member top live_top_level_dirs ->
      Live, "known_top_level_runtime_store"
    | _keeper :: child :: _ when member child live_keeper_child_dirs ->
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

let safe_lstat path =
  try Some (Unix.lstat path) with
  | Unix.Unix_error _ -> None
;;

let sorted_readdir path =
  try Sys.readdir path |> Array.to_list |> List.sort String.compare with
  | Sys_error _ -> []
;;

let scan_entries ~legacy_dir ~current_keepers_dir ~max_depth ~max_entries =
  let entries = ref [] in
  let visited = ref 0 in
  let truncated = ref false in
  let rec visit ~depth path =
    if !visited >= max_entries
    then truncated := true
    else (
      match safe_lstat path with
      | None -> ()
      | Some st ->
        incr visited;
        let kind = stat_kind st in
        let rel = relative_path ~root:legacy_dir path in
        let classification, reason = classify ~current_keepers_dir ~rel ~kind in
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
        then
          sorted_readdir path
          |> List.iter (fun name -> visit ~depth:(depth + 1) (Filename.concat path name)))
  in
  if Sys.file_exists legacy_dir
  then
    sorted_readdir legacy_dir
    |> List.iter (fun name -> visit ~depth:0 (Filename.concat legacy_dir name));
  List.rev !entries, !truncated, !visited
;;

let entry_to_json entry =
  `Assoc
    [ "path", `String entry.path
    ; "depth", `Int entry.depth
    ; "kind", `String entry.kind
    ; "bytes", `Int entry.bytes
    ; "class", `String (class_to_string entry.classification)
    ; "reason", `String entry.reason
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

let cleanup_candidate_class = function
  | Orphaned | Backup -> true
  | Live | Migrated | Unknown -> false
;;

let cleanup_plan_json entries =
  let candidates = List.filter (fun entry -> cleanup_candidate_class entry.classification) entries in
  let bytes = List.fold_left (fun acc entry -> acc + entry.bytes) 0 candidates in
  `Assoc
    [ "delete_allowed", `Bool false
    ; "requires_operator_approval", `Bool true
    ; "candidate_classes", `List [ `String "orphaned"; `String "backup" ]
    ; "candidate_count", `Int (List.length candidates)
    ; "candidate_bytes", `Int bytes
    ; "candidates", `List (List.map entry_to_json candidates)
    ]
;;

let legacy_keeper_inventory_http_json ~base_path ?(max_depth = default_max_depth)
      ?(max_entries = default_max_entries) () =
  let masc_root = Config_dir_resolver.masc_root ~base_path in
  let legacy_dir = Filename.concat masc_root "keepers" in
  let current_keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let entries, truncated, visited =
    scan_entries ~legacy_dir ~current_keepers_dir ~max_depth ~max_entries
  in
  `Assoc
    [ "base_path", `String base_path
    ; "legacy_keepers_path", `String legacy_dir
    ; "current_config_keepers_path", `String current_keepers_dir
    ; "exists", `Bool (Sys.file_exists legacy_dir)
    ; "read_only", `Bool true
    ; "max_depth", `Int max_depth
    ; "max_entries", `Int max_entries
    ; "visited_entries", `Int visited
    ; "truncated", `Bool truncated
    ; "class_totals", `Assoc (class_totals entries)
    ; "entries", `List (List.map entry_to_json entries)
    ; "dry_run_cleanup_plan", cleanup_plan_json entries
    ]
;;
