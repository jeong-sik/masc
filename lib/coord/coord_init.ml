(** Coord Init - Coord initialization, reset, pause, and resume.

    Extracted from Coord module. Handles room directory bootstrapping,
    state creation, and pause/resume lifecycle. *)

open Types
open Coord_utils
open Coord_state
open Coord_broadcast

(** Initialize MASC room *)
let init config ~agent_name =
  (* Ensure root .masc structure exists even when initializing a non-default room. *)
  let root_dir = masc_root_dir config in
  let root_agents_dir = Filename.concat root_dir "agents" in
  let root_keepers_dir = Filename.concat root_dir "keepers" in
  let root_traces_dir = Filename.concat root_dir "traces" in
  let root_tasks_dir = Filename.concat root_dir "tasks" in
  let root_messages_dir = Filename.concat root_dir "messages" in
  let root_backlog_path = Filename.concat root_tasks_dir "backlog.json" in
  List.iter mkdir_p
    [
      root_agents_dir;
      root_keepers_dir;
      root_traces_dir;
      root_tasks_dir;
      root_messages_dir;
    ];
  if not (path_exists_root config (root_state_path config)) then begin
    let root_state = {
      protocol_version = "0.1.0";
      project = Filename.basename config.base_path;
      started_at = now_iso ();
      message_seq = 0;
      active_agents = [];
      paused = false;
      pause_reason = None;
      paused_by = None;
      paused_at = None;
      search_strategy_default = Some "best_first_v1";
      speculation_enabled = false;
      speculation_budget = None;
    } in
    write_json_root config (root_state_path config) (room_state_to_yojson root_state)
  end else begin
    (* Sync PG state to local file on startup so filesystem fallback has fresh data *)
    let root_json = read_json_root config (root_state_path config) in
    (try write_json_local (root_state_path config) root_json
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Coord.warn "init: local sync of root state failed: %s" (Printexc.to_string exn))
  end;
  if not (path_exists_root config root_backlog_path) then begin
    let root_backlog = { tasks = []; last_updated = now_iso (); version = 1 } in
    write_json_root config root_backlog_path (backlog_to_yojson root_backlog)
  end else begin
    let root_backlog_json = read_json_root config root_backlog_path in
    (try write_json_local root_backlog_path root_backlog_json
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Coord.warn "init: local sync of root backlog failed: %s" (Printexc.to_string exn))
  end;

  if is_initialized config then begin
    (* Sync PG scoped state to local file so filesystem fallback has fresh data *)
    let scoped_json = read_json config (state_path config) in
    (try write_json_local (state_path config) scoped_json
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Coord.warn "init: local sync of scoped state failed: %s" (Printexc.to_string exn));
    "MASC already initialized."
  end
  else begin
    (* Create directories *)
    List.iter mkdir_p [
      agents_dir config;
      tasks_dir config;
      messages_dir config;
    ];

    (* Create initial state *)
    let state = {
      protocol_version = "0.1.0";
      project = Filename.basename config.base_path;
      started_at = now_iso ();
      message_seq = 0;
      active_agents = [];
      paused = false;
      pause_reason = None;
      paused_by = None;
      paused_at = None;
      search_strategy_default = Some "best_first_v1";
      speculation_enabled = false;
      speculation_budget = None;
    } in
    write_state config state;

    (* Preserve a migrated backlog when blocking bootstrap has already
       promoted legacy room state into the flattened root namespace. *)
    if not (path_exists config (backlog_path config)) then begin
      let backlog = { tasks = []; last_updated = now_iso (); version = 1 } in
      write_backlog config backlog
    end;

    let result = "✅ MASC room created!" in

    (* Auto-join if agent specified — uses Coord_lifecycle.join via the caller *)
    match agent_name with
    | Some _name -> result  (* Caller is responsible for joining after init *)
    | None -> result
  end

(** Pause the room - stops orchestrator from spawning new agents *)
let pause config ~by ~reason =
  let _ = update_state config (fun s -> {
    s with
    paused = true;
    pause_reason = Some reason;
    paused_by = Some by;
    paused_at = Some (now_iso ());
  }) in
  (* Broadcast pause notification *)
  let _ = broadcast config ~from_agent:"system"
    ~content:(Printf.sprintf "⏸️ Coord PAUSED by %s: %s" by reason) in
  ()

(** Resume the room *)
let resume config ~by =
  let state = read_state config in
  if not state.paused then
    `Already_running
  else begin
    let _ = update_state config (fun s -> {
      s with
      paused = false;
      pause_reason = None;
      paused_by = None;
      paused_at = None;
    }) in
    (* Broadcast resume notification *)
    let _ = broadcast config ~from_agent:"system"
      ~content:(Printf.sprintf "▶️ Coord RESUMED by %s" by) in
    `Resumed
  end

(** Reset room - delete .masc/ folder *)
let reset config =
  if not (is_initialized config) then
    "⚠ MASC not initialized. Nothing to reset."
  else begin
    (* Recursive delete *)
    let rec rm_rf path =
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name ->
          Coord_query.safe_yield ();
          rm_rf (Filename.concat path name)
        );
        Unix.rmdir path
      end else
        Sys.remove path
    in
    rm_rf (masc_dir config);
    Printf.sprintf "🗑️ MASC room reset! (.masc/ deleted at %s)" config.base_path
  end
