(* Server_runtime_startup_maintenance — startup pruning and keeper history cleanup.
   Extracted from server_runtime_bootstrap.ml during godfile decomposition.
   Contains JSONL/auth-archive pruning and keeper history migration. *)

(* ── Startup pruning ───────────────────────────────── *)

let startup_prune_jsonl (state : Mcp_server.server_state) =
  (try
     let days =
       Safe_ops.get_env_int_logged "MASC_JSONL_RETENTION_DAYS" ~default:30
     in
     let masc = Workspace.masc_dir (Mcp_server.workspace_config state) in
     let prune_dir dir =
       if Sys.file_exists dir then
         Dated_jsonl.prune (Dated_jsonl.create ~base_dir:dir ()) ~days
       else 0
     in
     let prune_recall_injections () =
       match
         Keeper_recall_injection_ledger.prune_older_than
           ~masc_root:masc
           ~retention_days:days
       with
       | Ok count -> count
       | Error label ->
         Log.Misc.warn
           "startup prune: recall_injections failed label=%s"
           (Keeper_recall_injection_ledger.string_of_prune_error label);
         0
     in
     let tool_metrics_dir =
       Filename.concat (Mcp_server.workspace_config state).base_path "data/tool-metrics"
     in
     let total =
       prune_dir (Filename.concat masc "audit")
       + prune_dir (Filename.concat masc "telemetry")
       + prune_dir (Filename.concat (Filename.concat masc "governance") "judgments")
       + prune_dir tool_metrics_dir
       + prune_dir (Filename.concat masc "messages")
       + prune_dir (Filename.concat masc "events")
       + prune_dir (Filename.concat masc "activity-events")
       + prune_recall_injections ()
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
         Log.Misc.info "startup prune: pruned %d old JSONL day-files (retention=%dd)"
         total days
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn -> Log.Misc.warn "startup prune failed: %s (next boot retries; disk impact bounded by retention)" (Printexc.to_string exn))

let startup_canonicalize_keeper_metas (state : Mcp_server.server_state) =
  (try
     Keeper_meta_store.canonicalize_persisted_meta_files
       (Mcp_server.workspace_config state)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.warn
       "startup keeper meta canonicalize failed: %s (next boot retries; stale keys keep warning on read)"
       (Printexc.to_string exn))

let startup_migrate_keeper_histories (state : Mcp_server.server_state) =
  (try
     let traces_dir =
       Filename.concat (Workspace.masc_root_dir (Mcp_server.workspace_config state)) "traces"
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
