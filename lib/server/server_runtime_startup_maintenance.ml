(* Server_runtime_startup_maintenance — startup pruning.
   Extracted from server_runtime_bootstrap.ml during godfile decomposition.
   Contains JSONL pruning and startup maintenance tasks. *)

(* ── Startup pruning ───────────────────────────────── *)

module Retention_directory = Fs_compat.Retention_directory

(* A flat-store file is [<name>.jsonl] or a numeric rotation sibling
   [<name>.jsonl.<n>] (runtime-manifests rotate whole files to [.jsonl.1],
   which a plain [.jsonl] suffix check would keep forever). Any other
   extension is never removed. *)
let is_flat_jsonl_file name =
  Filename.check_suffix name ".jsonl"
  ||
  match String.rindex_opt name '.' with
  | None -> false
  | Some dot ->
    let rot = String.sub name (dot + 1) (String.length name - dot - 1) in
    rot <> ""
    && String.for_all (fun c -> c >= '0' && c <= '9') rot
    && Filename.check_suffix (String.sub name 0 dot) ".jsonl"

(* Decisions use the observed mtime, and deletion remains relative to its
   held parent even if any pathname above it is replaced. The Fs_compat
   facade offloads each blocking operation; callbacks stay on their fiber. *)
let prune_flat_files_in ~matches ~days directory =
  if days <= 0 then 0
  else
    (* NDT-OK: file retention is explicitly measured against wall-clock mtime. *)
    let cutoff = Unix.gettimeofday () -. (float_of_int days *. Masc_time_constants.day) in
    Retention_directory.names directory
    |> List.fold_left (fun count name ->
      if matches name && Retention_directory.remove_regular_file ~older_than:cutoff directory name
      then count + 1 else count) 0

let prune_flat_jsonl_in ~days = prune_flat_files_in ~matches:is_flat_jsonl_file ~days

let prune_flat_jsonl_older_than ~days dir =
  if days <= 0 then 0
  else match Retention_directory.with_root dir (prune_flat_jsonl_in ~days) with
    | None -> 0
    | Some count -> count

let keeper_scoped_flat_stores = [ "raw-traces"; "runtime-manifests" ]

(* A Keeper's memory health row reads the newest turn record that carries a
   response observation, so removing its old day files can change the row.
   No other dated store is read by the row. *)
let pruned_store ~masc_root location =
  match Dated_jsonl.Store.keeper_store location with
  | Some (keeper, Dated_jsonl.Store.Keeper.Turn_records) ->
    Keeper_memory_health_input.written
      ~keepers_dir:(Filename.concat masc_root Common.keepers_runtime_dirname)
      ~keeper_id:keeper
  | Some
      ( _
      , Dated_jsonl.Store.Keeper.(
          ( Metrics | Execution_receipts | Provider_inputs | Memory_recall_artifacts
          | Crash_events | Continuity_requests )) )
  | None -> ()
;;

let completion_review_prefix = "completion-review-"

let completion_review_empty_subdirs =
  [ "continuity-requests"
  ; "turn-records"
  ; "metrics"
  ; "execution-receipts"
  ; "provider-inputs"
  ; "memory-recall-artifacts"
  ; "crash-events"
  ; "raw-traces"
  ; "runtime-manifests"
  ]
;;

let prune_empty_completion_review_dirs_bound held =
  Retention_directory.descend held [ Common.keepers_runtime_dirname ] (fun keepers ->
    let candidates =
      Retention_directory.names keepers
      |> List.filter (String.starts_with ~prefix:completion_review_prefix)
    in
    List.iter
      (fun name ->
         ignore
           (Retention_directory.with_child keepers name (fun review_dir ->
              List.iter
                (fun sub -> Retention_directory.remove_empty_child review_dir sub)
                completion_review_empty_subdirs));
         Retention_directory.remove_empty_child keepers name)
      candidates;
    let remaining =
      Retention_directory.names keepers
      |> List.filter (String.starts_with ~prefix:completion_review_prefix)
    in
    max 0 (List.length candidates - List.length remaining))
;;

let prune_empty_completion_review_dirs ~masc_root =
  let root = Dated_jsonl.Store.root_of_masc_dir masc_root in
  match Dated_jsonl.Store.with_retention_root root prune_empty_completion_review_dirs_bound with
  | None -> 0
  | Some count -> count
;;

(* Both startup and the periodic pass share one admitted physical root and
   the existing closed dated-store declarations/retention windows. *)
let prune_shared_jsonl_stores ~days ~masc_root =
  let root = Dated_jsonl.Store.root_of_masc_dir masc_root in
  match Dated_jsonl.Store.with_retention_root root (fun held ->
    let prune_children components =
      Retention_directory.descend held components (fun parent ->
        Retention_directory.fold_children parent ~init:0
          ~f:(fun count _name child -> count + prune_flat_jsonl_in ~days child)) in
    let removed_files =
      Dated_jsonl.prune_listed_stores_bound root held ~operator_window_days:days
        ~on_pruned:(pruned_store ~masc_root)
      + Retention_directory.descend held [ "logs" ] (prune_flat_jsonl_in ~days)
      + prune_children [ "trajectories" ]
      + prune_children [ Keeper_chat_event_log.events_dirname ]
      + prune_children [ Keeper_chat_event_log.turn_events_dirname ]
      + Retention_directory.descend held [ "messages" ]
          (prune_flat_files_in ~matches:(fun name -> Filename.check_suffix name ".json") ~days)
      + Retention_directory.descend held [ Common.keepers_runtime_dirname ] (fun keepers ->
          Retention_directory.fold_children keepers ~init:0
            ~f:(fun count _name keeper ->
              count + List.fold_left (fun count store ->
                count + Retention_directory.descend keeper [ store ] (prune_flat_jsonl_in ~days))
                0 keeper_scoped_flat_stores))
    in
    ignore (prune_empty_completion_review_dirs_bound held);
    removed_files) with
  | None -> 0
  | Some count -> count

type jsonl_prune_outcome = {
  pruned : int;
  days : int;
  source : Server_maintenance_toml_config.source;
  diagnostics : Server_maintenance_toml_config.diagnostic list;
}

let retention_source_label = function
  | Server_maintenance_toml_config.Env -> "env"
  | Server_maintenance_toml_config.Toml -> "runtime.toml"
  | Server_maintenance_toml_config.Default -> "default"

(* One prune at the workspace's resolved window. The startup pass and the
   24h periodic pass both call this, so the window comes from the same
   env -> runtime.toml -> default order in both. *)
let prune_jsonl_at_resolved_window ~base_path =
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  let config_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
  let days, source, diagnostics =
    Server_maintenance_toml_config.resolve_retention_days ~config_path
  in
  let invalidate = ref true in
  let pruned = Fun.protect ~finally:(fun () ->
    if !invalidate then Dashboard_observation_commit.written ~base_path ~scope:`Workspace `Telemetry)
    (fun () ->
      let removed = prune_shared_jsonl_stores ~days ~masc_root in
      invalidate := removed > 0;
      removed) in
  { pruned;
    days;
    source;
    diagnostics }

let startup_prune_jsonl (state : Mcp_server.server_state) =
  let config = Mcp_server.workspace_config state in
  let outcome = prune_jsonl_at_resolved_window ~base_path:config.base_path in
  List.iter
    (fun diagnostic ->
       Log.Misc.warn "startup prune: ignoring runtime.toml [maintenance]: %s"
         (Server_maintenance_toml_config.diagnostic_to_string diagnostic))
    outcome.diagnostics;
  if outcome.pruned > 0 then
    Log.Misc.info "startup prune: pruned %d old JSONL day-files (retention=%dd from %s)"
      outcome.pruned outcome.days (retention_source_label outcome.source)


(** Inventory maintenance excludes guest start/adoption through deletion.
    Apple preserves names derived from current readable declarations regardless
    of the previous server PID; unresolved inventories/declarations preserve.
    Other backend ownership rules remain runtime-specific. *)
let startup_sweep_microvm_guests (state : Mcp_server.server_state) =
  let timeout_sec = Env_config_sandbox.Runtime.microvm_remove_timeout_sec () in
  let config = Mcp_server.workspace_config state in
  let outcomes =
    Keeper_turn_sandbox_runtime.sweep_abandoned_microvm_guests
      ~base_path:config.base_path
      ~command_available:Executable_path.command_available
      ~timeout_sec
      ~is_pid_alive:Keeper_sandbox_runtime.pid_alive
      ~run_argv:(fun ~timeout_sec argv ->
        Process_eio.run_argv_with_status ~timeout_sec argv)
  in
  (match outcomes with
   | [] ->
     Log.Misc.info
       "startup microvm sweep swept no runtime: none of %s has both its CLI on \
        PATH and a guest listing this build can scope to a base path"
       (String.concat ", " Keeper_microvm_backend.valid_strings)
   | outcomes ->
     List.iter
       (fun (backend, (outcome : Keeper_sandbox_microvm.sweep_outcome)) ->
          (match outcome.removed with
           | [] -> ()
           | removed ->
             Log.Misc.info
               "startup sweep: removed %d abandoned %s guest(s): %s"
               (List.length removed)
               (Keeper_microvm_backend.to_string backend)
               (String.concat ", " removed));
          List.iter
            (fun (container_id, detail) ->
               Log.Misc.warn
                 "startup sweep: %s maintenance target %s could not settle: %s"
                 (Keeper_microvm_backend.to_string backend)
                 container_id
                 detail)
            outcome.failed)
       outcomes);
  match
    Keeper_turn_sandbox_runtime.sweep_abandoned_apple_policy_networks
      ~base_path:config.base_path
      ~command_available:Executable_path.command_available
      ~timeout_sec
  with
  | None -> ()
  | Some outcome ->
    (match outcome.removed with
     | [] -> ()
     | removed ->
       Log.Misc.info
         "startup sweep: removed %d abandoned Apple policy network(s): %s"
         (List.length removed)
         (String.concat ", " removed));
    List.iter
      (fun (target, detail) ->
         Log.Misc.warn
           "startup sweep: Apple policy network %s could not settle: %s"
           target
           detail)
      outcome.failed
;;

(* The pass counts instances every minute; the
   bytes are read here once, because the observation tree holds hundreds of
   thousands of files. *)
let startup_count_superseded_lanes (state : Mcp_server.server_state) =
  let config = Mcp_server.workspace_config state in
  match Lane_addon_runtime.superseded_reading ~config with
  | Error detail -> Log.Server.warn "[Startup] superseded Lane census: %s" detail
  | Ok { root; eligible; kept } ->
    (match
       Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
         Lane_addon_superseded_census.count ~root ~eligible ~kept)
     with
     | Error detail -> Log.Server.warn "[Startup] superseded Lane census: %s" detail
     | Ok report ->
       Log.Server.info
         "[Startup] superseded Lane census: eligible=%d eligible_bytes=%Ld kept=%d \
          kept_bytes=%Ld observations_bytes=%Ld"
         report.eligible report.eligible_bytes report.kept report.kept_bytes
         report.observations_bytes)
;;

(* [typesafeai].excluded_keepers names keepers by name, so a misspelt name
   excludes nobody and looks as if it did. The keepers of a base path are
   declared by <keepers_dir>/<name>.toml; each excluded name with no such
   declaration is reported, one line per name, when the server is up and the
   runtime table is loaded. The listing is a parameter so a test can point it
   at a directory of its own. *)
let declared_keeper_names ~keepers_dir =
  match Sys.readdir keepers_dir with
  | exception Sys_error detail -> Error detail
  | entries ->
    Ok
      (Array.to_list entries
       |> List.filter_map (fun entry ->
         if Filename.check_suffix entry ".toml"
         then Some (Filename.chop_suffix entry ".toml")
         else None))
;;

let unknown_typesafeai_exclusions ~keepers_dir =
  Result.map
    (fun known -> Typesafeai_config.unknown_excluded_keepers ~known)
    (declared_keeper_names ~keepers_dir)
;;

let report_unknown_typesafeai_exclusions ~base_path =
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  match unknown_typesafeai_exclusions ~keepers_dir with
  | Error detail ->
    Log.Server.warn
      "[typesafeai].excluded_keepers could not be checked against declarations in %s: %s"
      keepers_dir
      detail
  | Ok names ->
    List.iter
      (fun name ->
         Log.Server.warn
           "[typesafeai].excluded_keepers names %S, but no keeper of this base path is declared \
            by that name (%s/%s.toml): it excludes nobody"
           name
           keepers_dir
           name)
      names
;;

(* The same check for the keepers [memory_recall_keepers] limits recall to: a
   misspelt name limits recall to nobody by that name, and the keepers that
   are named right still get it. *)
let unknown_memory_recall_keepers ~keepers_dir =
  (* With an empty roster every listed name is unknown, so an empty answer
     means no name is listed: recall is off or covers every keeper. Then there
     is nothing to check and the directory is not read, so a base path without
     keepers does not warn about a key nobody set. *)
  match Typesafeai_config.unknown_memory_recall_keepers ~known:[] with
  | [] -> Ok []
  | _ :: _ ->
    Result.map
      (fun known -> Typesafeai_config.unknown_memory_recall_keepers ~known)
      (declared_keeper_names ~keepers_dir)
;;

let report_unknown_memory_recall_keepers ~base_path =
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  match unknown_memory_recall_keepers ~keepers_dir with
  | Error detail ->
    Log.Server.warn
      "[typesafeai].memory_recall_keepers could not be checked against declarations in %s: %s"
      keepers_dir
      detail
  | Ok names ->
    List.iter
      (fun name ->
         Log.Server.warn
           "[typesafeai].memory_recall_keepers names %S, but no keeper of this base path is \
            declared by that name (%s/%s.toml): recall reaches nobody by that name"
           name
           keepers_dir
           name)
      names
;;

let report_unarmed_typesafeai_destinations () =
  List.iter
    (fun (destination : Runtime_schema.typesafeai_destination) ->
       Log.Server.warn
         "[typesafeai].destinations names %s (%s), but its api_key_env %S holds no key: it is \
          left out of the walk"
         (Typesafeai_client.endpoint_for_observation destination.endpoint)
         destination.model
         destination.api_key_env)
    (Typesafeai_config.unarmed_destinations ())
;;

type task =
  | Jsonl_retention
  | Microvm_guest_sweep
  | Superseded_lane_census
  | Orphan_hygiene_sweep

let task_name = function
  | Jsonl_retention -> "jsonl_prune"
  | Microvm_guest_sweep -> "microvm_guest_sweep"
  | Superseded_lane_census -> "superseded_lane_census"
  | Orphan_hygiene_sweep -> "orphan_hygiene_sweep"

let is_lowercase_sha256_hex s =
  String.length s = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       s
;;

let path_is_absent path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true
  | _ -> false
  | exception Unix.Unix_error _ -> false
;;

let list_dir_entries_nofollow dir =
  match Unix.lstat dir with
  | stat when stat.Unix.st_kind = Unix.S_DIR ->
    (try Ok (Array.to_list (Sys.readdir dir)) with
     | Sys_error detail -> Error detail
     | Unix.Unix_error (err, _, _) -> Error (Unix.error_message err))
  | _ -> Ok []
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
  | exception Unix.Unix_error (err, _, _) -> Error (Unix.error_message err)
;;

(* Compute the newest mtime across a file or directory tree without following
   symlinks. Returns [None] if any symlink, wrong owner, or stat/read error is
   observed so callers fail closed and preserve the entry. *)
let rec tree_newest_mtime_nofollow ~expected_uid path =
  match Unix.lstat path with
  | exception Unix.Unix_error _ -> None
  | stat when stat.Unix.st_uid <> expected_uid -> None
  | stat ->
    (match stat.Unix.st_kind with
     | Unix.S_LNK -> None
     | Unix.S_DIR ->
       (match Sys.readdir path with
        | exception Sys_error _ -> None
        | exception Unix.Unix_error _ -> None
        | entries ->
          Array.fold_left
            (fun acc name ->
               match acc with
               | None -> None
               | Some current_max ->
                 (match
                    tree_newest_mtime_nofollow ~expected_uid (Filename.concat path name)
                  with
                  | None -> None
                  | Some child_max -> Some (Float.max current_max child_max)))
            (Some stat.Unix.st_mtime)
            entries)
     | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
       Some stat.Unix.st_mtime)
;;

(* Remove an owned file or directory tree bottom-up without following symlinks.
   Re-checks [lstat] ownership and file kind before every unlink/rmdir. *)
let rec remove_owned_tree_nofollow ~expected_uid path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | exception Unix.Unix_error (err, _, _) -> Error (Unix.error_message err)
  | stat when stat.Unix.st_uid <> expected_uid -> Error "entry is not owned by effective uid"
  | { Unix.st_kind = Unix.S_LNK; _ } -> Error "refusing to remove symbolic link"
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    (match Sys.readdir path with
     | exception Sys_error detail -> Error detail
     | exception Unix.Unix_error (err, _, _) -> Error (Unix.error_message err)
     | entries ->
       let children_result =
         Array.fold_left
           (fun acc name ->
              match acc with
              | Error _ as err -> err
              | Ok () -> remove_owned_tree_nofollow ~expected_uid (Filename.concat path name))
           (Ok ())
           entries
       in
       match children_result with
       | Error _ as err -> err
       | Ok () ->
         (match Unix.rmdir path with
          | () -> Ok ()
          | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
          | exception Unix.Unix_error (err, _, _) -> Error (Unix.error_message err)))
  | { Unix.st_kind = Unix.S_REG; _ } ->
    (match Unix.unlink path with
     | () -> Ok ()
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
     | exception Unix.Unix_error (err, _, _) -> Error (Unix.error_message err))
  | { Unix.st_kind = (Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK); _ } ->
    Error "refusing to remove non-regular filesystem entry"
;;

let prune_settled_verifier_executions ?now ~base_path ~days () =
  if days <= 0
  then Ok 0
  else (
    let masc_root = Common.masc_dir_from_base_path ~base_path in
    let exec_root = Filename.concat masc_root "verifier-executions" in
    match Fs_compat.inspect_owned_directory_chain ~ownership_root:base_path exec_root with
    | Error rejection ->
      Error (Fs_compat.owned_directory_chain_rejection_to_string rejection)
    | Ok Fs_compat.Owned_directory_missing -> Ok 0
    | Ok (Fs_compat.Owned_directory _) ->
      let store =
        Lane_addon_store.create ~root:(Lane_addon_store.directory ~masc_dir:masc_root)
      in
      (match
         Lane_addon_tool_request_owner.load_scope ~store ~scope:Verifier_review_owner.scope
       with
       | Error err -> Error (Lane_addon_tool_request_owner.error_to_string err)
       | Ok records ->
         let live_digests =
           List.fold_left
             (fun acc (record : Lane_addon_tool_request_owner.retained) ->
                Set_util.StringSet.add record.request_digest acc)
             Set_util.StringSet.empty
             records
         in
         (* NDT-OK: settled verifier execution retention is wall-clock mtime based. *)
         let now = match now with Some ts -> ts | None -> Unix.gettimeofday () in
         let cutoff = now -. (float_of_int days *. Masc_time_constants.day) in
         let expected_uid = Unix.geteuid () in
         (match list_dir_entries_nofollow exec_root with
          | Error detail -> Error detail
          | Ok entries ->
            let removed =
              List.fold_left
                (fun count name ->
                   if is_lowercase_sha256_hex name
                      && not (Set_util.StringSet.mem name live_digests)
                   then (
                     let path = Filename.concat exec_root name in
                     match Unix.lstat path with
                     | stat when stat.Unix.st_kind = Unix.S_DIR && stat.Unix.st_uid = expected_uid ->
                       (match tree_newest_mtime_nofollow ~expected_uid path with
                        | Some newest when newest <= cutoff ->
                          (match remove_owned_tree_nofollow ~expected_uid path with
                           | Ok () -> count + 1
                           | Error _ -> count)
                        | Some _ | None -> count)
                     | _ -> count
                     | exception Unix.Unix_error _ -> count)
                   else count)
                0
                entries
            in
            Ok removed)))
;;

let merge_atomic_reports (a : Fs_compat.atomic_orphan_cleanup_report)
    (b : Fs_compat.atomic_orphan_cleanup_report) =
  { Fs_compat.inspected = a.inspected + b.inspected
  ; deleted = a.deleted + b.deleted
  ; preserved = a.preserved + b.preserved
  ; failures = a.failures @ b.failures
  }
;;

let path_within_root ~root path =
  let norm p =
    match Unix.realpath p with
    | resolved -> resolved
    | exception Unix.Unix_error _ -> p
  in
  let r = norm root in
  let p = norm path in
  String.equal p r || String.starts_with ~prefix:(r ^ Filename.dir_sep) p
;;

let sweep_atomic_orphans ~base_path =
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  let recovery_parent =
    Filename.concat masc_root Fs_compat.Publication_recovery.directory_leaf
  in
  let sweep_one ?recovery_parent ?recovery_ownership_root ~ownership_root dir acc =
    let report =
      Fs_compat.cleanup_atomic_orphans
        ~unlink_private_jsonl_stages:true
        ?recovery_parent
        ?recovery_ownership_root
        ~ownership_root
        ~base_path:dir
        ()
    in
    merge_atomic_reports acc report
  in
  let empty = { Fs_compat.inspected = 0; deleted = 0; preserved = 0; failures = [] } in
  let keepers_dir = Filename.concat masc_root Common.keepers_runtime_dirname in
  let keeper_subdirs =
    match list_dir_entries_nofollow keepers_dir with
    | Error _ -> []
    | Ok names ->
      List.filter_map
        (fun name ->
           let path = Filename.concat keepers_dir name in
           match Unix.lstat path with
           | stat when stat.Unix.st_kind = Unix.S_DIR -> Some path
           | _ -> None
           | exception Unix.Unix_error _ -> None)
        names
  in
  let in_workspace_dirs =
    [ masc_root
    ; keepers_dir
    ; Filename.concat masc_root Workspace_init.traces_dirname
    ; Filename.concat masc_root Keeper_gate_path.dirname
    ]
    @ keeper_subdirs
  in
  let report =
    List.fold_left
      (fun acc dir ->
         sweep_one ~recovery_parent ~ownership_root:base_path dir acc)
      empty
      in_workspace_dirs
  in
  let config_keepers = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  if path_within_root ~root:base_path config_keepers
  then sweep_one ~recovery_parent ~ownership_root:base_path config_keepers report
  else
    (* Route external config_keepers recovery into classified
       <masc_root>/fs-publication-recovery rather than creating an unclassified
       <config_keepers>/.recovered directory that would stall Tool_blob_sweep. *)
    sweep_one
      ~recovery_parent
      ~recovery_ownership_root:base_path
      ~ownership_root:config_keepers
      config_keepers
      report
;;

type stale_lock_sweep_report =
  { removed : int
  ; kept_held : int
  ; kept_target_present : int
  ; failed : int
  }

let record_lock_outcome report = function
  | File_lock_eio.Stale_lock_removed -> { report with removed = report.removed + 1 }
  | File_lock_eio.Stale_lock_kept_held -> { report with kept_held = report.kept_held + 1 }
  | File_lock_eio.Stale_lock_kept_target_present ->
    { report with kept_target_present = report.kept_target_present + 1 }
  | File_lock_eio.Stale_lock_already_absent -> report
  | File_lock_eio.Stale_lock_cleanup_failed _ -> { report with failed = report.failed + 1 }
;;

let record_private_jsonl_lock_outcome report = function
  | Fs_compat.Private_jsonl_stale_lock_removed -> { report with removed = report.removed + 1 }
  | Fs_compat.Private_jsonl_stale_lock_kept_held -> { report with kept_held = report.kept_held + 1 }
  | Fs_compat.Private_jsonl_stale_lock_kept_target_present ->
    { report with kept_target_present = report.kept_target_present + 1 }
  | Fs_compat.Private_jsonl_stale_lock_already_absent -> report
  | Fs_compat.Private_jsonl_stale_lock_cleanup_failed _ -> { report with failed = report.failed + 1 }
;;

let antigravity_owner_leaf_of_lock_name name =
  let prefix = "antigravity-" in
  let suffix = ".prepare.lock" in
  if Runtime_antigravity_home.is_keeper_prepare_lock_name name
     && String.starts_with ~prefix name
     && Filename.check_suffix name suffix
  then (
    let plen = String.length prefix in
    let slen = String.length suffix in
    let len = String.length name - plen - slen in
    if len > 0
    then (
      let leaf = String.sub name plen len in
      if not (String.contains leaf '/') then Some leaf else None)
    else None)
  else None
;;

let sweep_stale_durable_locks ~base_path =
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  let init = { removed = 0; kept_held = 0; kept_target_present = 0; failed = 0 } in
  (* 1. antigravity-<owner_leaf>.prepare.lock (File_lock_eio-owned) *)
  let report =
    match list_dir_entries_nofollow masc_root with
    | Error _ -> init
    | Ok entries ->
      List.fold_left
        (fun acc name ->
           match antigravity_owner_leaf_of_lock_name name with
           | None -> acc
           | Some owner_leaf ->
             let lock_path = Filename.concat masc_root name in
             let target_dir =
               Runtime_antigravity_home.keeper_home_dir ~runtime_root:masc_root ~owner_leaf
             in
             record_lock_outcome
               acc
               (File_lock_eio.unlink_if_unheld
                  ~lock_path
                  ~target_absent:(fun () -> path_is_absent target_dir)))
        init
        entries
  in
  (* 2. board_attention_candidates/<sanitized_keeper>.jsonl.lock
        (Fs_compat private JSONL stable lock — must serialize with
        [Fs_compat.try_with_append_path_mutex], never [File_lock_eio]). *)
  let report =
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let protected_segments_opt =
      match Unix.lstat keepers_dir with
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Some []
      | _ ->
        (match Keeper_microvm_declared_guests.read ~base_path with
         | Error _ -> None
         | Ok declarations ->
           (match Keeper_microvm_declared_guests.protected_keeper_names declarations with
            | None -> None
            | Some names ->
              let segments =
                List.concat_map
                  (fun name ->
                     [ name; Workspace_utils_backend_setup.sanitize_namespace_segment name ])
                  names
              in
              Some segments))
    in
    match protected_segments_opt with
    | None -> report
    | Some protected_segments ->
      let dir = Filename.concat masc_root Keeper_board_attention_candidate.dirname in
      (match list_dir_entries_nofollow dir with
       | Error _ -> report
       | Ok entries ->
         List.fold_left
           (fun acc name ->
              if Filename.check_suffix name ".jsonl.lock"
              then (
                let keeper_segment = Filename.chop_suffix name ".jsonl.lock" in
                if keeper_segment = "" || List.mem keeper_segment protected_segments
                then { acc with kept_target_present = acc.kept_target_present + 1 }
                else
                  let target_file = Filename.concat dir (keeper_segment ^ ".jsonl") in
                  let toml_file = Filename.concat keepers_dir (keeper_segment ^ ".toml") in
                  record_private_jsonl_lock_outcome
                    acc
                    (Fs_compat.unlink_private_jsonl_stable_lock_if_unheld
                       ~data_path:target_file
                       ~target_absent:(fun () ->
                         path_is_absent target_file && path_is_absent toml_file)))
              else acc)
           report
           entries)
  in
  (* 3. artifact_drafts/<id>.json.lock (Fs_compat private JSONL stable lock) *)
  let report =
    let dir = Filename.concat masc_root Artifact_draft_store.dirname in
    match list_dir_entries_nofollow dir with
    | Error _ -> report
    | Ok entries ->
      List.fold_left
        (fun acc name ->
           if Filename.check_suffix name ".json.lock"
           then (
             let base = Filename.chop_suffix name ".lock" in
             let target_file = Filename.concat dir base in
             record_private_jsonl_lock_outcome
               acc
               (Fs_compat.unlink_private_jsonl_stable_lock_if_unheld
                  ~data_path:target_file
                  ~target_absent:(fun () -> path_is_absent target_file)))
           else acc)
        report
        entries
  in
  (* 4. traces/<session>.checkpoint.lock (File_lock_eio-owned) *)
  let traces_dir = Filename.concat masc_root Workspace_init.traces_dirname in
  match list_dir_entries_nofollow traces_dir with
  | Error _ -> report
  | Ok entries ->
    List.fold_left
      (fun acc name ->
         if Filename.check_suffix name ".checkpoint.lock"
         then (
           let session = Filename.chop_suffix name ".checkpoint.lock" in
           if session = ""
           then acc
           else
             let lock_path = Filename.concat traces_dir name in
             let target_path = Filename.concat traces_dir session in
             record_lock_outcome
               acc
               (File_lock_eio.unlink_if_unheld
                  ~lock_path
                  ~target_absent:(fun () -> path_is_absent target_path)))
         else acc)
      report
      entries
;;

type temp_orphan_sweep_report =
  { removed_files : int
  ; removed_dirs : int
  ; skipped_live : int
  ; failed : int
  }

type temp_entry_class =
  | Temp_pid_dir of int
  | Temp_pid_file of int
  | Temp_aged_dir
  | Temp_aged_file
  | Temp_aged_any
  | Temp_unrelated

let parse_positive_pid_after ~prefix ~sep ~suffix name =
  if String.starts_with ~prefix name && String.ends_with ~suffix name
  then (
    let plen = String.length prefix in
    let slen = String.length suffix in
    let body_len = String.length name - plen - slen in
    if body_len <= 1
    then None
    else (
      let body = String.sub name plen body_len in
      match String.index_opt body sep with
      | Some idx when idx > 0 ->
        let pid_str = String.sub body 0 idx in
        if String.for_all (fun c -> c >= '0' && c <= '9') pid_str
        then (
          match int_of_string_opt pid_str with
          | Some pid when pid > 0 -> Some pid
          | Some _ | None -> None)
        else None
      | Some _ | None -> None))
  else None
;;

let classify_temp_entry name =
  match parse_positive_pid_after ~prefix:"masc-completion-review-" ~sep:'-' ~suffix:"" name with
  | Some pid -> Temp_pid_dir pid
  | None ->
    (match parse_positive_pid_after ~prefix:"masc-agy-acp-" ~sep:'-' ~suffix:"" name with
     | Some pid -> Temp_pid_dir pid
     | None ->
       (match parse_positive_pid_after ~prefix:"masc-claude-system-" ~sep:'-' ~suffix:".txt" name with
        | Some pid -> Temp_pid_file pid
        | None ->
          (match
             parse_positive_pid_after ~prefix:"masc_process_eio_stderr_" ~sep:'_' ~suffix:".tmp" name
           with
           | Some pid -> Temp_pid_file pid
           | None ->
             (* Untagged [masc-agy-acp-*] dirs may belong to long-lived persistent
                ACP children (>24h) whose static config files are never rewritten,
                so only PID-tagged [masc-agy-acp-<pid>-*] dirs are reclaimed here. *)
             if String.starts_with ~prefix:"masc-antigravity-usage-" name
             then Temp_aged_any
             else if String.starts_with ~prefix:"masc-completion-review-" name
             then Temp_aged_dir
             else if String.starts_with ~prefix:"masc-claude-system-" name
                     && String.ends_with ~suffix:".txt" name
             then Temp_aged_file
             else if String.starts_with ~prefix:"masc_process_eio_stderr" name
                     && String.ends_with ~suffix:".tmp" name
             then Temp_aged_file
             else Temp_unrelated)))
;;

let sweep_stale_temp_orphans
      ?(temp_dir = Filename.get_temp_dir_name ())
      ?(min_age_seconds = Masc_time_constants.day)
      ?(is_pid_alive = Keeper_sandbox_runtime.pid_alive)
      ?now
      ()
  =
  let init = { removed_files = 0; removed_dirs = 0; skipped_live = 0; failed = 0 } in
  (* NDT-OK: temp artifact age retention is wall-clock mtime based. *)
  let now = match now with Some ts -> ts | None -> Unix.gettimeofday () in
  let cutoff = now -. Float.max 0.0 min_age_seconds in
  let my_pid = Unix.getpid () in
  let expected_uid = Unix.geteuid () in
  match list_dir_entries_nofollow temp_dir with
  | Error _ -> init
  | Ok entries ->
    List.fold_left
      (fun acc name ->
         let entry_class = classify_temp_entry name in
         match entry_class with
         | Temp_unrelated -> acc
         | Temp_pid_dir pid | Temp_pid_file pid ->
           if pid = my_pid || is_pid_alive pid
           then { acc with skipped_live = acc.skipped_live + 1 }
           else (
             let path = Filename.concat temp_dir name in
             match Unix.lstat path with
             | exception Unix.Unix_error _ -> acc
             | stat when stat.Unix.st_uid <> expected_uid -> acc
             | stat ->
               (match entry_class, stat.Unix.st_kind with
                | Temp_pid_dir _, Unix.S_DIR ->
                  (match remove_owned_tree_nofollow ~expected_uid path with
                   | Ok () -> { acc with removed_dirs = acc.removed_dirs + 1 }
                   | Error _ -> { acc with failed = acc.failed + 1 })
                | Temp_pid_file _, Unix.S_REG ->
                  (match remove_owned_tree_nofollow ~expected_uid path with
                   | Ok () -> { acc with removed_files = acc.removed_files + 1 }
                   | Error _ -> { acc with failed = acc.failed + 1 })
                | (Temp_pid_dir _ | Temp_pid_file _ | Temp_aged_dir | Temp_aged_file | Temp_aged_any | Temp_unrelated),
                  (Unix.S_REG | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK) ->
                  acc))
         | Temp_aged_dir | Temp_aged_file | Temp_aged_any ->
           let path = Filename.concat temp_dir name in
           (match Unix.lstat path with
            | exception Unix.Unix_error _ -> acc
            | stat when stat.Unix.st_uid <> expected_uid -> acc
            | stat ->
              let st_kind = stat.Unix.st_kind in
              let kind_matches =
                match entry_class, st_kind with
                | Temp_aged_dir, Unix.S_DIR -> true
                | Temp_aged_file, Unix.S_REG -> true
                | Temp_aged_any, (Unix.S_DIR | Unix.S_REG) -> true
                | (Temp_aged_dir | Temp_aged_file | Temp_aged_any | Temp_pid_dir _ | Temp_pid_file _ | Temp_unrelated),
                  (Unix.S_REG | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK) ->
                  false
              in
              if not kind_matches
              then acc
              else (
                match tree_newest_mtime_nofollow ~expected_uid path with
                | None -> { acc with skipped_live = acc.skipped_live + 1 }
                | Some newest when newest > cutoff ->
                  { acc with skipped_live = acc.skipped_live + 1 }
                | Some _ ->
                  (match remove_owned_tree_nofollow ~expected_uid path with
                   | Ok () ->
                     (match st_kind with
                      | Unix.S_DIR -> { acc with removed_dirs = acc.removed_dirs + 1 }
                      | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
                        { acc with removed_files = acc.removed_files + 1 })
                   | Error _ -> { acc with failed = acc.failed + 1 }))))
      init
      entries
;;

let startup_sweep_orphan_hygiene (state : Mcp_server.server_state) =
  let config = Mcp_server.workspace_config state in
  let base_path = config.base_path in
  let config_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
  let days, _, _ = Server_maintenance_toml_config.resolve_retention_days ~config_path in
  let atomic, locks, shutdown_res, verifier_res, temp =
    Systhread_host.run ~label:"orphan-hygiene-sweep" (fun () ->
      let atomic = sweep_atomic_orphans ~base_path in
      let locks = sweep_stale_durable_locks ~base_path in
      let shutdown_res =
        Keeper_shutdown_store.prune_terminal_and_empty_dirs
          ~config
          ~older_than_seconds:(float_of_int days *. Masc_time_constants.day)
          ()
      in
      let verifier_res = prune_settled_verifier_executions ~base_path ~days () in
      let temp = sweep_stale_temp_orphans () in
      atomic, locks, shutdown_res, verifier_res, temp)
  in
  let shutdown_ops, shutdown_dirs =
    match shutdown_res with
    | Ok report -> report.pruned_operations, report.pruned_empty_dirs
    | Error err ->
      Log.Server.warn
        "startup orphan hygiene: shutdown operation prune skipped: %s"
        (Keeper_shutdown_store.error_to_string err);
      0, 0
  in
  let verifier_dirs =
    match verifier_res with
    | Ok count -> count
    | Error detail ->
      Log.Server.warn
        "startup orphan hygiene: verifier-executions prune skipped: %s"
        detail;
      0
  in
  List.iter
    (fun failure ->
       Log.Server.warn
         "startup orphan hygiene: atomic orphan failure: %s"
         (Fs_compat.atomic_orphan_cleanup_failure_to_string failure))
    atomic.failures;
  Log.Server.info
    "startup orphan hygiene: atomic_deleted=%d atomic_preserved=%d atomic_failures=%d \
     locks_removed=%d locks_kept_held=%d locks_failed=%d shutdown_ops=%d shutdown_dirs=%d \
     verifier_exec_dirs=%d temp_files=%d temp_dirs=%d temp_skipped_live=%d temp_failed=%d"
    atomic.deleted
    atomic.preserved
    (List.length atomic.failures)
    locks.removed
    locks.kept_held
    locks.failed
    shutdown_ops
    shutdown_dirs
    verifier_dirs
    temp.removed_files
    temp.removed_dirs
    temp.skipped_live
    temp.failed
;;

let start_maintenance ~sw ~task ~run =
  Eio.Fiber.fork ~sw (fun () ->
    let name = task_name task in
    let started_at = Unix.gettimeofday () in
    Log.Server.info "startup maintenance: starting %s" name;
    try
      run ();
      Eio.Fiber.check ();
      Log.Server.info
        "startup maintenance: finished %s elapsed_s=%.3f" name
        (Unix.gettimeofday () -. started_at)
    with
    | Eio.Cancel.Cancelled _ as exn ->
      Log.Server.info "startup maintenance: cancelled %s" name;
      raise exn
    | exn ->
      Log.Server.warn "startup maintenance: %s failed: %s" name
        (Printexc.to_string exn))
;;
