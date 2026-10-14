(* Server_runtime_startup_maintenance — startup pruning.
   Extracted from server_runtime_bootstrap.ml during godfile decomposition.
   Contains JSONL and auth-archive pruning. *)

(* ── Startup pruning ───────────────────────────────── *)

(* Fold [prune_dir] over the immediate sub-directories of [root].
   A missing [root] counts 0; stray files and broken links under [root]
   are skipped. *)
let prune_children_dirs ~prune_dir root =
  List.fold_left
    (fun acc name -> acc + prune_dir (Filename.concat root name))
    0
    (Fs_compat.subdirectory_names root)

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

(* Remove the regular files in [dir] whose name [matches] and whose mtime is
   older than [days]. A missing [dir] counts 0. The directory read and the
   unlinks run on a system thread (#42935). *)
let prune_flat_files_older_than ~matches ~days dir =
  if days <= 0
  then 0
  else
    Eio_guard.run_in_systhread ~label:"flat-file-prune" (fun () ->
      if not (Sys.file_exists dir)
      then 0
      else (
        let cutoff =
          (* NDT-OK: wall clock is the retention boundary for mtime pruning; idempotent cleanup, never feeds deterministic replay. *)
          Unix.gettimeofday () -. (float_of_int days *. Masc_time_constants.day)
        in
        Array.fold_left
          (fun acc name ->
            if matches name
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
          (Sys.readdir dir)))

(* Trajectory stores are flat [<trace_id>.jsonl] files under
   [trajectories/<keeper>/] — no [YYYY-MM] month dirs — so
   [Dated_jsonl.prune] is a provable no-op on them.  Prune by file mtime
   instead, folded keeper-scoped via [prune_children_dirs]. *)
let prune_flat_jsonl_older_than ~days dir =
  prune_flat_files_older_than ~matches:is_flat_jsonl_file ~days dir

(* Keeper-scoped flat-JSONL stores ([keepers/<name>/<store>] holding
   [<id>.jsonl] files plus numeric rotation siblings, no month dirs).
   Pruned by mtime via [prune_flat_jsonl_older_than] in BOTH passes.
   Both stores had no retention since introduction (raw-traces: one file per turn; runtime-manifests:
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

(* messages/: flat [<seq>_<agent>_<id>_broadcast.json] files — one JSON per
   message, no month dirs. Prune by file mtime like the [.jsonl] stores.
   Any other extension is never removed. *)
let prune_flat_json_older_than ~days dir =
  prune_flat_files_older_than ~matches:(fun name -> Filename.check_suffix name ".json") ~days dir

(* Every retention-covered JSONL store in one fold. Both the startup pass
   and the 24h periodic pass call exactly this function, so the covered-store
   set cannot drift between them again. Date-split stores are pruned from
   their list ([Dated_jsonl.prune_listed_stores]); the rest below are flat
   files pruned by mtime. *)
let prune_shared_jsonl_stores ~days ~masc_root =
  Dated_jsonl.prune_listed_stores
    (Dated_jsonl.Store.root_of_masc_dir masc_root)
    ~operator_window_days:days
  (* logs/: flat [system_log_YYYY-MM-DD.jsonl] day files (406 MB by
     2026-07-31, single day up to 180 MB). The active day file keeps a
     fresh mtime, so only closed day files age out. *)
  + prune_flat_jsonl_older_than ~days (Filename.concat masc_root "logs")
  (* trajectories: flat <trace_id>.jsonl under trajectories/<keeper>/,
     pruned by mtime keeper-scoped. *)
  + prune_children_dirs
      ~prune_dir:(prune_flat_jsonl_older_than ~days)
      (Filename.concat masc_root "trajectories")
  (* keeper_chat_events: flat <operation_id>.jsonl under
     keeper_chat_events/<keeper>/ (RFC-0412 stage 1). Same mtime safety as
     logs/: a live operation's journal keeps a fresh mtime, so only finished
     operations age out. These files hold full reasoning text — aging out is
     the privacy posture, not just disk hygiene. *)
  + prune_children_dirs
      ~prune_dir:(prune_flat_jsonl_older_than ~days)
      (Filename.concat masc_root Keeper_chat_event_log.events_dirname)
  + prune_children_dirs
      ~prune_dir:(prune_flat_jsonl_older_than ~days)
      (Filename.concat masc_root Keeper_chat_event_log.turn_events_dirname)
  + prune_flat_json_older_than ~days (Filename.concat masc_root "messages")
  + prune_keeper_scoped_flat_stores ~days ~masc_root

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
let prune_jsonl_at_resolved_window ~base_path ~masc_root =
  let config_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
  let days, source, diagnostics =
    Server_maintenance_toml_config.resolve_retention_days ~config_path
  in
  { pruned = prune_shared_jsonl_stores ~days ~masc_root;
    days;
    source;
    diagnostics }

let startup_prune_jsonl (state : Mcp_server.server_state) =
  (try
     let config = Mcp_server.workspace_config state in
     let outcome =
       prune_jsonl_at_resolved_window ~base_path:config.base_path
         ~masc_root:(Workspace.masc_dir config)
     in
     List.iter
       (fun diagnostic ->
          Log.Misc.warn "startup prune: ignoring runtime.toml [maintenance]: %s"
            (Server_maintenance_toml_config.diagnostic_to_string diagnostic))
       outcome.diagnostics;
     if outcome.pruned > 0 then
         Log.Misc.info "startup prune: pruned %d old JSONL day-files (retention=%dd from %s)"
         outcome.pruned outcome.days (retention_source_label outcome.source)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn -> Log.Misc.warn "startup prune failed: %s (next boot retries; disk impact bounded by retention)" (Printexc.to_string exn))


(** Collect abandoned guests without making unrelated Keeper readiness wait
    for VM shutdown. The runtime serializes the entire inventory/removal pass
    with boot and teardown, since a stable name can be reused after restart.
    Live owners remain outside the collection set. *)
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
  match outcomes with
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
              "startup sweep: removed %d %s guest(s) whose server is gone: %s"
              (List.length removed)
              (Keeper_microvm_backend.to_string backend)
              (String.concat ", " removed));
         List.iter
           (fun (container_id, detail) ->
              Log.Misc.warn
                "startup sweep: %s guest %s survived removal: %s"
                (Keeper_microvm_backend.to_string backend)
                container_id
                detail)
           outcome.failed)
      outcomes
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

let start_microvm_guest_maintenance ~sw ~sweep =
  Eio.Fiber.fork ~sw (fun () ->
    let started_at = Unix.gettimeofday () in
    Log.Server.info "startup maintenance: starting microvm_guest_sweep";
    try
      sweep ();
      Eio.Fiber.check ();
      Log.Server.info
        "startup maintenance: finished microvm_guest_sweep elapsed_s=%.3f"
        (Unix.gettimeofday () -. started_at)
    with
    | Eio.Cancel.Cancelled _ as exn ->
      Log.Server.info "startup maintenance: cancelled microvm_guest_sweep";
      raise exn
    | exn ->
      Log.Server.warn "startup maintenance: microvm_guest_sweep failed: %s"
        (Printexc.to_string exn))
;;
