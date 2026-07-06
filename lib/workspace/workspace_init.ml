(** Workspace Init - Workspace initialization, reset, pause, and resume.

    Extracted from Workspace module. Handles workspace directory bootstrapping,
    state creation, and pause/resume lifecycle. *)

open Masc_domain
open Workspace_utils
open Workspace_state
open Workspace_backlog
open Workspace_broadcast
open Workspace_backlog

(** Initialize MASC workspace state *)
let init config ~agent_name =
  invalidate_initialized_cache ();
  (* Ensure root .masc structure exists even when initializing a non-default workspace. *)
  let root_dir = masc_root_dir config in
  let root_agents_dir = Filename.concat root_dir "agents" in
  let root_keepers_dir = Filename.concat root_dir "keepers" in
  let root_traces_dir = Filename.concat root_dir "traces" in
  let root_tasks_dir = Filename.concat root_dir "tasks" in
  let root_messages_dir = Filename.concat root_dir "messages" in
  let root_backlog_path = Filename.concat root_tasks_dir "backlog.json" in
  List.iter
    mkdir_p
    [ root_agents_dir
    ; root_keepers_dir
    ; root_traces_dir
    ; root_tasks_dir
    ; root_messages_dir
    ];
  if not (path_exists_root config (root_state_path config))
  then (
    let root_state =
      { protocol_version = "0.1.0"
      ; project = Filename.basename config.base_path
      ; started_at = now_iso ()
      ; message_seq = 0
      ; active_agents = []
      ; paused = false
      ; pause_reason = None
      ; paused_by = None
      ; paused_at = None
      ; search_strategy_default = Some "best_first_v1"
      ; speculation_enabled = false
      ; speculation_budget = None
      }
    in
    match
      write_json_root_result config (root_state_path config)
        (workspace_state_to_yojson root_state)
    with
    | Ok () -> ()
    | Error error -> raise (Sys_error error))
  else (
    (* Sync PG state to local file on startup so filesystem fallback has fresh data *)
    match read_json_root_result config (root_state_path config) with
    | Error msg -> Log.Workspace.warn "init: root state read for local sync failed: %s" msg
    | Ok root_json -> (
        match write_json_local (root_state_path config) root_json with
        | Ok () -> ()
        | Error msg -> Log.Workspace.warn "init: local sync of root state failed: %s" msg));
  if not (path_exists_root config root_backlog_path)
  then (
    let root_backlog = { tasks = []; last_updated = now_iso (); version = 1 } in
    match
      write_json_root_result config root_backlog_path
        (backlog_to_yojson root_backlog)
    with
    | Ok () -> ()
    | Error error -> raise (Sys_error error))
  else (
    match read_json_root_result config root_backlog_path with
    | Error msg -> Log.Workspace.warn "init: root backlog read for local sync failed: %s" msg
    | Ok root_backlog_json -> (
        match write_json_local root_backlog_path root_backlog_json with
        | Ok () -> ()
        | Error msg -> Log.Workspace.warn "init: local sync of root backlog failed: %s" msg));
  if is_initialized config
  then (
    (* Sync PG scoped state to local file so filesystem fallback has fresh data *)
    (match read_json_result config (state_path config) with
     | Error msg -> Log.Workspace.warn "init: scoped state read for local sync failed: %s" msg
     | Ok scoped_json -> (
         match write_json_local (state_path config) scoped_json with
         | Ok () -> ()
         | Error msg -> Log.Workspace.warn "init: local sync of scoped state failed: %s" msg));
    "MASC already initialized.")
  else (
    (* Create directories *)
    List.iter mkdir_p [ agents_dir config; tasks_dir config; messages_dir config ];
    (* Create initial state *)
    let state =
      { protocol_version = "0.1.0"
      ; project = Filename.basename config.base_path
      ; started_at = now_iso ()
      ; message_seq = 0
      ; active_agents = []
      ; paused = false
      ; pause_reason = None
      ; paused_by = None
      ; paused_at = None
      ; search_strategy_default = Some "best_first_v1"
      ; speculation_enabled = false
      ; speculation_budget = None
      }
    in
    write_state config state;
    invalidate_initialized_cache ();
    (* Preserve a migrated backlog when blocking bootstrap has already
       promoted legacy workspace state into the flattened root namespace. *)
    if not (path_exists config (backlog_path config))
    then (
      let backlog = { tasks = []; last_updated = now_iso (); version = 1 } in
      write_backlog config backlog);
    let result = "MASC workspace created!" in
    (* Auto-join if agent specified — uses Workspace_lifecycle.join via the caller *)
    match agent_name with
    | Some _name -> result (* Caller is responsible for joining after init *)
    | None -> result)
;;

(** Pause workspace automation - stops orchestrator from spawning new agents *)
let pause config ~by ~reason =
  let _ =
    update_state config (fun s ->
      { s with
        paused = true
      ; pause_reason = Some reason
      ; paused_by = Some by
      ; paused_at = Some (now_iso ())
      })
  in
  (* Broadcast pause notification *)
  let _ =
    broadcast
      config
      ~from_agent:"system"
      ~content:(Printf.sprintf "⏸️ Workspace PAUSED by %s: %s" by reason)
  in
  ()
;;

(** Resume workspace automation *)
let resume_result config ~by =
  let snapshot = read_state_snapshot config in
  match snapshot.status with
  | State_default_from_read_error ->
    Error (Printf.sprintf "state read failed: %s" (String.concat "; " snapshot.read_errors))
  | State_authoritative | State_recovered_unpersisted ->
  if not snapshot.state.paused
  then Ok `Already_running
  else
    let _ =
      update_state config (fun s ->
        { s with paused = false; pause_reason = None; paused_by = None; paused_at = None })
    in
    (* Broadcast resume notification *)
    let _ =
      broadcast
        config
        ~from_agent:"system"
        ~content:(Printf.sprintf "▶️ Workspace RESUMED by %s" by)
    in
    Ok `Resumed
;;

let resume config ~by =
  match resume_result config ~by with
  | Ok result -> result
  | Error msg ->
    Log.Workspace.error "resume failed: %s" msg;
    `Already_running
;;

(** Reset workspace state - delete .masc/ folder *)
let reset config =
  if not (is_initialized config)
  then "MASC not initialized. Nothing to reset."
  else (
    (* Recursive delete *)
    let rec rm_rf path =
      if Sys.is_directory path
      then (
        Sys.readdir path
        |> Array.iter (fun name ->
          Workspace_query.safe_yield ();
          rm_rf (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
    in
    rm_rf (masc_dir config);
    invalidate_initialized_cache ();
    Printf.sprintf "MASC workspace reset! (.masc/ deleted at %s)" config.base_path)
;;
