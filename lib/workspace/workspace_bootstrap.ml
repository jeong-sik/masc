(** Workspace Bootstrap - Directory initialization and default state.

    Extracted from workspace_state.ml to isolate the "init or not"
    responsibility from runtime state I/O. *)

open Masc_domain
open Workspace_utils

let default_workspace_state config = {
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
}

let ensure_workspace_bootstrap config =
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
  if not (path_exists_root config (root_state_path config)) then (
    match
      write_json_root_result config (root_state_path config)
        (workspace_state_to_yojson (default_workspace_state config))
    with
    | Ok () -> ()
    | Error error -> raise (Sys_error error));
  if not (path_exists_root config root_backlog_path) then (
    match
      write_json_root_result config root_backlog_path
        (backlog_to_yojson { tasks = []; last_updated = now_iso (); version = 1 })
    with
    | Ok () -> ()
    | Error error -> raise (Sys_error error));

  let scoped_agents = agents_dir config in
  let scoped_tasks = tasks_dir config in
  let scoped_messages = messages_dir config in
  let scoped_state = state_path config in
  let scoped_backlog = backlog_path config in
  List.iter mkdir_p [ masc_dir config; scoped_agents; scoped_tasks; scoped_messages ];
  if not (path_exists config scoped_state) then (
    match
      write_json_result config scoped_state
        (workspace_state_to_yojson (default_workspace_state config))
    with
    | Ok () -> ()
    | Error error -> raise (Sys_error error));
  if not (path_exists config scoped_backlog) then
    Workspace_backlog.write_backlog config
      { tasks = []; last_updated = now_iso (); version = 1 }
