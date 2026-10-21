(* Server_runtime_startup_maintenance — startup pruning.
   Extracted from server_runtime_bootstrap.ml during godfile decomposition.
   Contains JSONL and auth-archive pruning. *)

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

(* Both startup and the periodic pass share one admitted physical root and
   the existing closed dated-store declarations/retention windows. *)
let prune_shared_jsonl_stores ~days ~masc_root =
  let root = Dated_jsonl.Store.root_of_masc_dir masc_root in
  match Dated_jsonl.Store.with_retention_root root (fun held ->
    let prune_children components =
      Retention_directory.descend held components (fun parent ->
        Retention_directory.fold_children parent ~init:0
          ~f:(fun count _name child -> count + prune_flat_jsonl_in ~days child)) in
    Dated_jsonl.prune_listed_stores_bound root held ~operator_window_days:days
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
              0 keeper_scoped_flat_stores))) with
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
  { pruned = prune_shared_jsonl_stores ~days ~masc_root;
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

type task = Jsonl_retention | Microvm_guest_sweep

let task_name = function
  | Jsonl_retention -> "jsonl_prune"
  | Microvm_guest_sweep -> "microvm_guest_sweep"

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
