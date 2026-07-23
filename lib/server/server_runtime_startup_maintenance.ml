(* Server_runtime_startup_maintenance — startup pruning and keeper history cleanup.
   Extracted from server_runtime_bootstrap.ml during godfile decomposition.
   Contains JSONL/auth-archive pruning and keeper history migration. *)

(* ── Startup pruning ───────────────────────────────── *)

(* Fold [prune_dir] over the immediate sub-directories of [root].
   A missing [root] counts 0 and stray files under [root] are skipped —
   [.masc/resilience_audit/<keeper>/] stores keep their day-files one
   level below the keeper dir, so per-keeper traversal needs the same
   guard the keepers loop gets for free from its nested path concat. *)
let prune_children_dirs ~prune_dir root =
  if not (Sys.file_exists root) then 0
  else
    Array.fold_left
      (fun acc name ->
        let dir = Filename.concat root name in
        if Sys.is_directory dir then acc + prune_dir dir else acc)
      0
      (Sys.readdir root)

(* Keeper-scoped dated-JSONL stores pruned by BOTH the startup pass and the
   24h periodic pass. SSOT: both loops fold this exact list via
   [prune_keeper_scoped_stores] — never reintroduce an inline store list in
   either caller (the periodic pass once pruned only execution-receipts,
   letting metrics/crash-events accumulate until restart). *)
let keeper_scoped_dated_stores = [ "metrics"; "crash-events"; "execution-receipts" ]

(* Fold [prune_dir] over every keeper-scoped dated store
   ([keepers/<name>/<store>] for each store in [keeper_scoped_dated_stores]).
   Built on [prune_children_dirs], so a missing keepers root counts 0 and
   stray files under it are skipped. *)
let prune_keeper_scoped_stores ~prune_dir ~masc_root =
  prune_children_dirs
    ~prune_dir:(fun keeper_dir ->
      List.fold_left
        (fun acc store -> acc + prune_dir (Filename.concat keeper_dir store))
        0
        keeper_scoped_dated_stores)
    (Filename.concat masc_root "keepers")

(* Trajectory stores are flat [<trace_id>.jsonl] files under
   [trajectories/<keeper>/] — no [YYYY-MM] month dirs — so
   [Dated_jsonl.prune] is a provable no-op on them.  Prune by file mtime
   instead, folded keeper-scoped via [prune_children_dirs]. *)
let prune_flat_jsonl_older_than ~days dir =
  if days <= 0 || not (Sys.file_exists dir)
  then 0
  else
    let cutoff =
      (* NDT-OK: wall clock is the retention boundary for mtime pruning; idempotent cleanup, never feeds deterministic replay. *)
      Unix.gettimeofday () -. (float_of_int days *. Masc_time_constants.day)
    in
    Array.fold_left
      (fun acc name ->
        if Filename.check_suffix name ".jsonl"
        then
          let path = Filename.concat dir name in
          match (try Some (Unix.stat path) with Unix.Unix_error _ -> None) with
          | Some (stat : Unix.stats)
            when stat.st_kind = Unix.S_REG && stat.st_mtime < cutoff ->
            (try
               Sys.remove path;
               acc + 1
             with Sys_error _ -> acc)
          | _ -> acc
        else acc)
      0
      (Sys.readdir dir)

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
       + prune_dir tool_metrics_dir
       + prune_dir (Filename.concat masc "messages")
       + prune_dir (Filename.concat masc "events")
       + prune_dir (Filename.concat masc "activity-events")
       + prune_recall_injections ()
       + prune_dir (Filename.concat masc "voice_sessions")
       (* trajectories: flat <trace_id>.jsonl under trajectories/<keeper>/ —
          Dated_jsonl.prune is a no-op there, prune by mtime keeper-scoped. *)
       + prune_children_dirs
           ~prune_dir:(prune_flat_jsonl_older_than ~days)
           (Filename.concat masc "trajectories")
       (* Top-level masc/"execution-receipts" has no writer (canonical layout
          is keepers/<name>/<store>), so keeper-scoped stores are pruned via
          the SSOT fold shared with the 24h periodic pass. *)
       + prune_keeper_scoped_stores ~prune_dir ~masc_root:masc
       + prune_children_dirs ~prune_dir (Filename.concat masc "resilience_audit")
     in
     if total > 0 then
         Log.Misc.info "startup prune: pruned %d old JSONL day-files (retention=%dd)"
         total days
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn -> Log.Misc.warn "startup prune failed: %s (next boot retries; disk impact bounded by retention)" (Printexc.to_string exn))

let startup_recover_keeper_lifecycle_transactions
      (state : Mcp_server.server_state)
  =
  let summary =
    Keeper_dead_revival_transaction.recover_pending
      (Mcp_server.workspace_config state)
  in
  Log.Keeper.info
    "startup keeper lifecycle recovery recovered=%d cleared=%d unresolved=%d"
    summary.recovered
    summary.cleared
    (List.length summary.unresolved);
  List.iter
    (fun (path, detail) ->
       Log.Keeper.error
         "startup keeper lifecycle recovery unresolved journal=%s detail=%s"
         path
         detail)
    summary.unresolved

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
