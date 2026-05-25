(* Server_runtime_startup_maintenance — legacy migration and startup pruning.
   Extracted from server_runtime_bootstrap.ml during godfile decomposition.
   Contains directory migration (perpetual→traces, resident-keepers→keepers,
   room flatten), JSONL/auth-archive pruning, and keeper history
   migration. *)

(** Migrate legacy directory names: perpetual->traces, resident-keepers->keepers.
    Moves contents via recursive merge. Conflicting files go to _quarantine/,
    except keeper meta files where a fresher valid legacy record may replace a
    stale or invalid current record. *)
let keeper_meta_updated_ts (meta : Keeper_types.keeper_meta) =
  Coord_resilience.Time.parse_iso8601_opt meta.updated_at
  |> Option.value ~default:0.0

let should_promote_legacy_keeper_meta ~legacy_path ~current_path =
  match
    Keeper_types.read_meta_file_path legacy_path,
    Keeper_types.read_meta_file_path current_path
  with
  | Ok (Some _legacy), Ok (Some _current) ->
      keeper_meta_updated_ts _legacy > keeper_meta_updated_ts _current
  | Ok (Some _), Ok None | Ok (Some _), Error _ -> true
  | _ -> false

let migrate_legacy_dirs_with_renames (state : Mcp_server.server_state) renames =
  let masc_root = Coord.masc_root_dir state.room_config in
  let quarantine_rel_path ~source_name ~rel_path =
    if rel_path = "" then source_name else Filename.concat source_name rel_path
  in
  let quarantine = Filename.concat masc_root "_quarantine" in
  let quarantine_replaced_path ~source_name ~rel_path =
    Filename.concat quarantine
      (Filename.concat "_replaced"
         (quarantine_rel_path ~source_name ~rel_path))
  in
  let rec migrate_recursive ~source_name ~old_dir ~new_dir ~rel_path
      ~prefer_root_keeper_meta_conflicts
      ~prefer_room_flatten_conflicts =
    if not (Sys.file_exists old_dir) then ()
    else begin
      (* ensure_dir returns the created path; fire-and-forget *)
      ignore (Keeper_fs.ensure_dir new_dir);
      Array.iter (fun name ->
        let old_path = Filename.concat old_dir name in
        let new_path = Filename.concat new_dir name in
        let rel = if rel_path = "" then name else Filename.concat rel_path name in
        if Sys.is_directory old_path then begin
          if Sys.file_exists new_path then
            migrate_recursive ~source_name ~old_dir:old_path ~new_dir:new_path ~rel_path:rel
              ~prefer_root_keeper_meta_conflicts
              ~prefer_room_flatten_conflicts
          else
            Sys.rename old_path new_path
        end else begin
          if Sys.file_exists new_path then begin
            if prefer_root_keeper_meta_conflicts && rel_path = ""
               && Filename.check_suffix name ".json"
               && should_promote_legacy_keeper_meta
                    ~legacy_path:old_path ~current_path:new_path
            then begin
              let replaced_q_path = quarantine_replaced_path ~source_name ~rel_path:rel in
              (* fire-and-forget: ensure_dir returns path *)
              ignore (Keeper_fs.ensure_dir (Filename.dirname replaced_q_path));
              Sys.rename new_path replaced_q_path;
              Sys.rename old_path new_path
            end else if prefer_room_flatten_conflicts then begin
              let replaced_q_path = quarantine_replaced_path ~source_name ~rel_path:rel in
              (* fire-and-forget: ensure_dir returns path *)
              ignore (Keeper_fs.ensure_dir (Filename.dirname replaced_q_path));
              Sys.rename new_path replaced_q_path;
              Sys.rename old_path new_path
            end else begin
              let q_path =
                Filename.concat quarantine
                  (quarantine_rel_path ~source_name ~rel_path:rel)
              in
              (* fire-and-forget: ensure_dir returns path *)
              ignore (Keeper_fs.ensure_dir (Filename.dirname q_path));
              Sys.rename old_path q_path
            end
          end else
            Sys.rename old_path new_path
        end
      ) (Sys.readdir old_dir);
      (try
        if Array.length (Sys.readdir old_dir) = 0 then
          Sys.rmdir old_dir
        else
          Log.Misc.warn "migrate: old dir not empty after migration: %s" old_dir
      with Sys_error _ -> ())
    end
  in
  (try
    List.iter (fun (old_name, new_name) ->
      let old_dir = Filename.concat masc_root old_name in
      let new_dir = Filename.concat masc_root new_name in
      if Sys.file_exists old_dir then begin
        Log.Misc.info "migrate: %s -> %s" old_name new_name;
        migrate_recursive ~source_name:old_name ~old_dir ~new_dir ~rel_path:""
          ~prefer_root_keeper_meta_conflicts:(String.equal new_name "keepers")
          ~prefer_room_flatten_conflicts:(String.starts_with ~prefix:"rooms/" old_name)
      end
    ) renames
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Misc.error "legacy dir migration failed: %s" (Printexc.to_string exn))

let migrate_legacy_dirs (state : Mcp_server.server_state) =
  migrate_legacy_dirs_with_renames state
    [ ("perpetual", "traces"); ("resident-keepers", "keepers") ]

let migrate_legacy_keeper_dirs_blocking (state : Mcp_server.server_state) =
  migrate_legacy_dirs_with_renames state [ ("resident-keepers", "keepers") ]

let default_room_for_flat_migration = "focus-room"

let legacy_room_candidates rooms_dir =
  if not (Sys.file_exists rooms_dir) then []
  else
    Safe_ops.protect ~default:[] (fun () ->
      Sys.readdir rooms_dir
      |> Array.to_list
      |> List.filter_map (fun room_id ->
           let room_path = Filename.concat rooms_dir room_id in
           if Sys.is_directory room_path then
             let trimmed_room_id = String.trim room_id in
             if not (String.equal room_id trimmed_room_id) then begin
               Log.Misc.warn
                 "migrate: ignoring invalid legacy room dir %S (must not have leading/trailing whitespace)"
                 room_id;
               None
             end else
               match Coord.validate_room_id room_id with
               | Ok valid_room_id -> Some valid_room_id
               | Error msg ->
                 Log.Misc.warn
                   "migrate: ignoring invalid legacy room dir %s (%s)" room_id msg;
                 None
           else
             None))

let infer_current_room_from_legacy_dirs rooms_dir =
  match legacy_room_candidates rooms_dir with
  | [ room_id ] ->
      Log.Misc.info
        "migrate: current_room unavailable; using only legacy room %s" room_id;
      Some room_id
  | room_ids when List.mem default_room_for_flat_migration room_ids ->
      Log.Misc.info
        "migrate: current_room unavailable; using legacy room %s"
        default_room_for_flat_migration;
      Some default_room_for_flat_migration
  | [] -> None
  | room_ids ->
      Log.Misc.warn
        "migrate: current_room unavailable and multiple legacy rooms exist (%s); skipping room flatten"
        (String.concat ", " room_ids);
      None

let load_current_room_or_default masc_root rooms_dir =
  let path = Filename.concat masc_root "current_room" in
  if not (Sys.file_exists path) then
    infer_current_room_from_legacy_dirs rooms_dir
  else
    match Safe_ops.read_file_safe path with
    | Error msg ->
        Log.Misc.warn
          "migrate: failed to read %s (%s); probing legacy room dirs instead"
          path msg;
        infer_current_room_from_legacy_dirs rooms_dir
    | Ok raw -> (
        match Coord.validate_room_id (String.trim raw) with
        | Ok room_id -> Some room_id
        | Error msg ->
            Log.Misc.warn
              "migrate: ignoring invalid current_room in %s (%s); probing legacy room dirs instead"
              path msg;
            infer_current_room_from_legacy_dirs rooms_dir)

let migrate_room_to_flat (state : Mcp_server.server_state) =
  let masc_root = Coord.masc_root_dir state.room_config in
  let rooms_dir = Filename.concat masc_root "rooms" in
  if not (Sys.file_exists rooms_dir) then ()
  else begin
    match load_current_room_or_default masc_root rooms_dir with
    | Some current_room ->
        let room_dir = Filename.concat rooms_dir current_room in
        if Sys.file_exists room_dir && Sys.is_directory room_dir then begin
          Log.Misc.info "migrate: flattening room %s to .masc/ root" current_room;
          migrate_legacy_dirs_with_renames state
            [ (Filename.concat "rooms" current_room, ".") ]
        end else if current_room = "default" then
          Log.Misc.info "migrate: legacy rooms/ exists but default room not found (likely already flattened)"
        else
          Log.Misc.warn "migrate: rooms/ exists but active room %s not found" current_room
    | None ->
        Log.Misc.warn
          "migrate: rooms/ exists but no safe current room could be inferred; leaving legacy room dirs untouched"
  end

let migrate_legacy_trace_dirs (state : Mcp_server.server_state) =
  migrate_legacy_dirs_with_renames state [ ("perpetual", "traces") ]

(* ── Startup pruning ───────────────────────────────── *)

let startup_prune_jsonl (state : Mcp_server.server_state) =
  (try
     let days =
       Safe_ops.get_env_int_logged "MASC_JSONL_RETENTION_DAYS" ~default:30
     in
     let masc = Coord.masc_dir state.room_config in
     let prune_dir dir =
       if Sys.file_exists dir then
         Dated_jsonl.prune (Dated_jsonl.create ~base_dir:dir ()) ~days
       else 0
     in
     let tool_metrics_dir =
       Filename.concat state.room_config.base_path "data/tool-metrics"
     in
     let total =
       prune_dir (Filename.concat masc "audit")
       + prune_dir (Filename.concat masc "telemetry")
       + prune_dir (Filename.concat (Filename.concat masc "governance") "judgments")
       + prune_dir tool_metrics_dir
       + prune_dir (Filename.concat masc "messages")
       + prune_dir (Filename.concat masc "events")
       + prune_dir (Filename.concat masc "activity-events")
       + prune_dir (Filename.concat masc "voice_sessions")
       + (let keepers = Filename.concat masc "keepers" in
          if not (Sys.file_exists keepers) then 0
          else
            Array.fold_left (fun acc name ->
              acc
              + prune_dir (Filename.concat (Filename.concat keepers name) "metrics")
              + prune_dir (Filename.concat (Filename.concat keepers name) "crash-events")
            ) 0 (Sys.readdir keepers))
     in
     if total > 0 then
         Log.Misc.info "startup prune: deleted %d old JSONL day-files (retention=%dd)"
         total days
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn -> Log.Misc.warn "startup prune failed: %s (next boot retries; disk impact bounded by retention)" (Printexc.to_string exn))

let startup_prune_auth_archive (state : Mcp_server.server_state) =
  (try
     let days =
       Safe_ops.get_env_int_logged
         "MASC_AUTH_ARCHIVE_RETENTION_DAYS"
         ~default:30
     in
     let min_keep =
       Safe_ops.get_env_int_logged
         "MASC_AUTH_ARCHIVE_MIN_KEEP"
         ~default:20
     in
     let kept, pruned =
       Auth.prune_archive
         ~base_path:state.room_config.base_path
         ~retention_days:days
         ~min_keep
     in
     Prometheus.set_gauge Prometheus.metric_auth_archive_epochs
       (float_of_int kept);
     if pruned > 0 then (
       Prometheus.inc_counter Prometheus.metric_auth_archive_pruned_total
         ~delta:(float_of_int pruned)
         ();
       Log.Misc.info
         "startup auth archive prune: pruned=%d kept=%d (retention=%dd \
          min_keep=%d)"
         pruned kept days min_keep)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.warn
       "startup auth archive prune failed: %s (next boot retries; disk \
        impact bounded by retention)"
       (Printexc.to_string exn))

let startup_migrate_keeper_histories (state : Mcp_server.server_state) =
  (try
     let traces_dir =
       Filename.concat (Coord.masc_root_dir state.room_config) "traces"
     in
     if Sys.file_exists traces_dir then begin
       let moved_total = ref 0 in
       let dropped_total = ref 0 in
       let sessions_migrated = ref 0 in
       Array.iter
         (fun trace_name ->
            let trace_dir = Filename.concat traces_dir trace_name in
            if Sys.is_directory trace_dir then
              let stats =
                Keeper_context_core.migrate_session_history_logs
                  ~session_dir:trace_dir
              in
              if stats.moved_lines > 0 || stats.dropped_lines > 0 then begin
                incr sessions_migrated;
                moved_total := !moved_total + stats.moved_lines;
                dropped_total := !dropped_total + stats.dropped_lines;
                Log.Misc.info
                  "startup history migration: trace=%s moved=%d dropped=%d kept=%d malformed=%d"
                  trace_name
                  stats.moved_lines
                  stats.dropped_lines
                  stats.kept_lines
                  stats.malformed_lines
              end)
         (Sys.readdir traces_dir);
       if !sessions_migrated > 0 then
         Log.Misc.info
           "startup history migration: migrated %d session(s), moved %d internal line(s), dropped %d prompt line(s)"
           !sessions_migrated
           !moved_total
           !dropped_total
     end
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
       Log.Misc.warn "startup history migration failed: %s (next boot retries; legacy format readable)"
         (Printexc.to_string exn))
