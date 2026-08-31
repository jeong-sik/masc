(* Server_runtime_startup_maintenance — startup pruning.
   Extracted from server_runtime_bootstrap.ml during godfile decomposition.
   Contains JSONL and auth-archive pruning. *)

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
   24h periodic pass. Both loops fold this via [prune_keeper_scoped_stores] —
   never reintroduce an inline store list in either caller (the periodic pass
   once pruned only execution-receipts, letting metrics/crash-events accumulate
   until restart).

   The list is derived rather than written. It used to be four directory names
   spelled out here, and turn-records — added to the store table on 2026-07-31
   with the same dated layout — was absent from it for months at roughly 4 MB a
   day fleet-wide. [Common.keeper_runtime_store_placement] now answers for each
   store and the match there is exhaustive, so a new store cannot reach disk
   without someone saying which pass owns it. *)
let keeper_scoped_dated_stores =
  List.filter_map
    (fun store ->
       match Common.keeper_runtime_store_placement store with
       | Common.Keeper_scoped_dated ->
         Some (Common.keeper_runtime_store_dirname store)
       | Common.Keeper_scoped_versioned
       | Common.Keeper_scoped_rotated
       | Common.Workspace_scoped -> None)
    Common.keeper_runtime_stores

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
    (Filename.concat masc_root Common.keepers_runtime_dirname)

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
        if is_flat_jsonl_file name
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

(* Keeper-scoped flat-JSONL stores ([keepers/<name>/<store>] holding
   [<id>.jsonl] files plus numeric rotation siblings, no month dirs).
   Pruned by mtime via [prune_flat_jsonl_older_than] in BOTH passes.
   SSOT like [keeper_scoped_dated_stores]. Both stores had no retention
   since introduction (raw-traces: one file per turn; runtime-manifests:
   one rotated JSONL per trace). *)
let keeper_scoped_flat_stores = [ "raw-traces"; "runtime-manifests" ]

let prune_keeper_scoped_flat_stores ~days ~masc_root =
  prune_children_dirs
    ~prune_dir:(fun keeper_dir ->
      List.fold_left
        (fun acc store ->
          acc + prune_flat_jsonl_older_than ~days (Filename.concat keeper_dir store))
        0
        keeper_scoped_flat_stores)
    (Filename.concat masc_root Common.keepers_runtime_dirname)

(* Top-level dated-JSONL stores under the masc root pruned by BOTH the
   startup pass and the 24h periodic pass. SSOT: replaces the two inline
   sums that had already drifted apart — the startup pass lacked
   tool_calls/transition-audit while the periodic pass lacked
   resilience_audit. Tool metrics now prune their SQLite rows while hydrating,
   so this list contains JSONL stores only.
   agent-core-events joined 2026-07-31: 434 MB accumulated with no retention.
   costs and audit-approvals joined 2026-08-05: both write the same
   [YYYY-MM/DD.jsonl] shape through [Dated_jsonl.create]
   ([cost_ledger.ml:250], [keeper_approval_queue.ml:1732]) yet were on no
   prune list since introduction — 74 MB and 22 MB measured. *)
let top_level_dated_stores =
  [ Audit_log.store_dirname
  ; "telemetry"
  ; "events"
  ; Activity_graph.store_dirname
  ; "voice_sessions"
  ; "tool_calls"
  ; Keeper_transition_audit.store_dirname
  ; "agent-core-events"
  ; "costs"
  ; "audit-approvals"
  ; "tool_usage"
  ]

(* messages/: flat [<seq>_<agent>_<id>_broadcast.json] files — one JSON per
   message, no month dirs, so [Dated_jsonl.prune] was a provable no-op for the
   whole time "messages" sat on the dated list (2,587 files measured live).
   Prune by file mtime, mirroring [prune_flat_jsonl_older_than] for the [.json]
   suffix. Any other extension is never removed. *)
let prune_flat_json_older_than ~days dir =
  if days <= 0 || not (Sys.file_exists dir)
  then 0
  else
    let cutoff =
      (* NDT-OK: wall clock is the retention boundary for mtime pruning; idempotent cleanup, never feeds deterministic replay. *)
      Unix.gettimeofday () -. (float_of_int days *. Masc_time_constants.day)
    in
    Array.fold_left
      (fun acc name ->
        if Filename.check_suffix name ".json"
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

(* Keeper-scoped versioned stores ([keepers/<name>/<store>/<generation>/
   YYYY-MM/DD.jsonl] — reaction-ledger's [v7/2026-08/27.jsonl] shape). The
   placement filter used to drop [Keeper_scoped_versioned] on the floor, and
   even on the dated list the pruner would have seen only the generation dir
   and returned 0, so these stores had no retention since introduction. Fold
   the dated pruner one level deeper, per generation dir. *)
let keeper_scoped_versioned_stores =
  List.filter_map
    (fun store ->
       match Common.keeper_runtime_store_placement store with
       | Common.Keeper_scoped_versioned ->
         Some (Common.keeper_runtime_store_dirname store)
       | Common.Keeper_scoped_dated
       | Common.Keeper_scoped_rotated
       | Common.Workspace_scoped -> None)
    Common.keeper_runtime_stores

let prune_keeper_scoped_versioned_stores ~prune_dir ~masc_root =
  prune_children_dirs
    ~prune_dir:(fun keeper_dir ->
      List.fold_left
        (fun acc store ->
          acc
          + prune_children_dirs ~prune_dir (Filename.concat keeper_dir store))
        0
        keeper_scoped_versioned_stores)
    (Filename.concat masc_root Common.keepers_runtime_dirname)

(* Single shared fold over every retention-covered JSONL store. Both the
   startup pass and the 24h periodic pass call exactly this function, so
   the covered-store set cannot drift between them again. [prune_dir] is
   the caller's dated pruner (Dated_jsonl-based in production). *)
let prune_shared_jsonl_stores ~prune_dir ~days ~masc_root =
  List.fold_left
    (fun acc store -> acc + prune_dir (Filename.concat masc_root store))
    0
    top_level_dated_stores
  (* logs/: flat [system_log_YYYY-MM-DD.jsonl] day files (406 MB by
     2026-07-31, single day up to 180 MB). The active day file keeps a
     fresh mtime, so only closed day files age out. *)
  + prune_flat_jsonl_older_than ~days (Filename.concat masc_root "logs")
  (* trajectories: flat <trace_id>.jsonl under trajectories/<keeper>/ —
     Dated_jsonl.prune is a no-op there, prune by mtime keeper-scoped. *)
  + prune_children_dirs
      ~prune_dir:(prune_flat_jsonl_older_than ~days)
      (Filename.concat masc_root "trajectories")
  + prune_children_dirs ~prune_dir (Filename.concat masc_root "resilience_audit")
  (* decision_audit: [<keeper>/YYYY-MM/DD.jsonl] written via
     [Keeper_decision_audit.append] ([keeper_decision_audit.ml:185]). Same
     keeper-scoped dated shape as resilience_audit, so it folds the same way;
     it lives at the masc root rather than under keepers/, which is why it is
     not in [keeper_scoped_dated_stores]. 23 MB measured with no retention. *)
  + prune_children_dirs ~prune_dir (Filename.concat masc_root "decision_audit")
  + prune_flat_json_older_than ~days (Filename.concat masc_root "messages")
  + prune_keeper_scoped_stores ~prune_dir ~masc_root
  + prune_keeper_scoped_versioned_stores ~prune_dir ~masc_root
  + prune_keeper_scoped_flat_stores ~days ~masc_root

let startup_prune_jsonl (state : Mcp_server.server_state) =
  (try
     let days =
       Env_config_core.jsonl_retention_days ()
     in
     let masc = Workspace.masc_dir (Mcp_server.workspace_config state) in
     let prune_dir dir =
       if Sys.file_exists dir then
         Dated_jsonl.prune (Dated_jsonl.create ~base_dir:dir ()) ~days
       else 0
     in
     let total =
       prune_shared_jsonl_stores ~prune_dir ~days ~masc_root:masc
     in
     if total > 0 then
         Log.Misc.info "startup prune: pruned %d old JSONL day-files (retention=%dd)"
         total days
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn -> Log.Misc.warn "startup prune failed: %s (next boot retries; disk impact bounded by retention)" (Printexc.to_string exn))


(** Collect microvm guests whose owning server is gone.

    Boot is the honest moment for it. A guest is keeper-lifetime, so nothing
    about its age or its idleness says it is abandoned; what does is its
    [masc.mcp.owner_pid] naming a process that no longer exists. At boot this
    process owns no guest yet, so every candidate belongs to an earlier
    server -- and any of those still running keeps its own pid alive, which
    is what stops a second server from collecting a first one's guests.

    Failure is logged, not fatal. A leaked guest costs memory; a boot that
    refuses to finish costs the whole fleet.

    Removing a guest is a VM shutdown and takes about a minute each
    (measured 63-67s on container 1.3.0), so this is not something keeper
    boot should wait behind -- see the group it is registered in. *)
let startup_sweep_microvm_guests (_state : Mcp_server.server_state) =
  try
    let timeout_sec = Env_config_sandbox.Runtime.microvm_remove_timeout_sec () in
    let outcome =
      Keeper_sandbox_microvm.sweep_abandoned_guests
        ~command_available:Executable_path.command_available
        ~timeout_sec
        ~is_pid_alive:Keeper_sandbox_runtime.pid_alive
        ~run_argv:(fun ~timeout_sec argv ->
          Process_eio.run_argv_with_status ~timeout_sec argv)
    in
    match outcome with
    | None ->
      Log.Misc.info
        "startup microvm sweep skipped: `container` CLI is not available on PATH"
    | Some outcome ->
      (match outcome.removed with
       | [] -> ()
       | removed ->
         Log.Misc.info
           "startup sweep: removed %d microvm guest(s) whose server is gone: %s"
           (List.length removed)
           (String.concat ", " removed));
      List.iter
        (fun (container_id, detail) ->
           Log.Misc.warn
             "startup sweep: microvm guest %s survived removal: %s"
             container_id
             detail)
        outcome.failed
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Misc.warn
      "startup microvm sweep failed: %s (next boot retries; a leaked guest \
       costs memory, a refused boot costs the fleet)"
      (Printexc.to_string exn)
;;
