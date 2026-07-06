(** Operator dashboard workspace descriptor, extracted from
    [operator_control_snapshot.ml] (godfile decomp).

    [workspace_json config] produces a minimal workspace-state summary for the
    operator dashboard:

    - When the workspace is not yet initialized via [Workspace.init], returns
      `{initialized=false, project=basename(base_path)}` so the
      dashboard can render a placeholder before any keeper has
      bootstrapped the workspace root.

    - When initialized, returns the full snapshot: cluster name,
      project, paused state with reason/by/at, tempo interval,
      agent/task counts, and the current message_seq.

    Pure helper move — local-only function with no .mli surface. *)

let workspace_json config =
  let initialized = Workspace.is_initialized config in
  if not initialized
  then
    `Assoc
      [ "initialized", `Bool false
      ; "project", `String (Filename.basename config.base_path)
      ]
  else (
    let state_snapshot = Workspace.read_state_snapshot config in
    let state = state_snapshot.state in
    let tempo = Tempo.get_tempo config in
    let tasks = Workspace.get_tasks_raw config in
    let agents = Workspace.get_agents_raw config in
    `Assoc
      [ "initialized", `Bool true
      ; "cluster", `String (Env_config_core.cluster_name ())
      ; "project", `String state.project
      ; ( "workspace_state_status"
        , `String (Workspace.read_state_status_to_string state_snapshot.status) )
      ; "workspace_state_read_error_count", `Int (List.length state_snapshot.read_errors)
      ; ( "workspace_state_read_errors"
        , `List (List.map (fun error -> `String error) state_snapshot.read_errors) )
      ; "paused", `Bool state.paused
      ; "pause_reason", Json_util.string_opt_to_json state.pause_reason
      ; "paused_by", Json_util.string_opt_to_json state.paused_by
      ; "paused_at", Json_util.string_opt_to_json state.paused_at
      ; "tempo_interval_s", `Float tempo.current_interval_s
      ; "agent_count", `Int (List.length agents)
      ; "task_count", `Int (List.length tasks)
      ; "message_seq", `Int state.message_seq
      ])
;;
