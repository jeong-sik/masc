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

let task_ownership_json config =
  match Workspace.read_backlog_r config with
  | Error message ->
    `Assoc
      [ "available", `Bool false
      ; "error", `String message
      ]
  | Ok backlog ->
    let items =
      List.filter_map
        (fun (task : Masc_domain.task) ->
           match task.task_status with
           | Masc_domain.Claimed { assignee; _ }
           | Masc_domain.InProgress { assignee; _ } ->
             Some
               (`Assoc
                 [ "task_id", `String task.id
                 ; "title", `String task.title
                 ; ( "status"
                   , `String (Masc_domain.task_status_to_string task.task_status) )
                 ; "assignee", `String assignee
                 ])
           | Masc_domain.Todo
           | Masc_domain.AwaitingVerification _
           | Masc_domain.Done _
           | Masc_domain.Cancelled _ ->
             None)
        backlog.tasks
    in
    `Assoc
      [ "available", `Bool true
      ; "backlog_version", `Int backlog.version
      ; "items", `List items
      ; "count", `Int (List.length items)
      ]
;;

let workspace_json config =
  let initialized = Workspace.is_initialized config in
  if not initialized
  then
    `Assoc
      [ "initialized", `Bool false
      ; "project", `String (Filename.basename config.base_path)
      ]
  else (
    let state = Workspace.read_state config in
    let tempo = Tempo.get_tempo config in
    let tasks = Workspace.get_tasks_raw config in
    let agents = Workspace.get_agents_raw config in
    `Assoc
      [ "initialized", `Bool true
      ; "cluster", `String (Env_config_core.cluster_name ())
      ; "project", `String state.project
      ; "paused", `Bool state.paused
      ; "pause_reason", Json_util.string_opt_to_json state.pause_reason
      ; "paused_by", Json_util.string_opt_to_json state.paused_by
      ; "paused_at", Json_util.string_opt_to_json state.paused_at
      ; "tempo_interval_s", `Float tempo.current_interval_s
      ; "agent_count", `Int (List.length agents)
      ; "task_count", `Int (List.length tasks)
      ; "task_ownership", task_ownership_json config
      ; "message_seq", `Int state.message_seq
      ])
;;
