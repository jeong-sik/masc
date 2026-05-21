(** Operator dashboard room descriptor, extracted from
    [operator_control_snapshot.ml] (godfile decomp).

    [room_json config] produces a minimal room-state summary for the
    operator dashboard:

    - When the room is not yet initialized via [Coord.init], returns
      `{initialized=false, project=basename(base_path)}` so the
      dashboard can render a placeholder before any keeper has
      bootstrapped the coordination root.

    - When initialized, returns the full snapshot: cluster name,
      project, paused state with reason/by/at, tempo interval,
      agent/task counts, and the current message_seq.

    Pure helper move — local-only function with no .mli surface. *)

let room_json config =
  let initialized = Coord.is_initialized config in
  if not initialized
  then
    `Assoc
      [ "initialized", `Bool false
      ; "project", `String (Filename.basename config.base_path)
      ]
  else (
    let state = Coord.read_state config in
    let tempo = Tempo.get_tempo config in
    let tasks = Coord.get_tasks_raw config in
    let agents = Coord.get_agents_raw config in
    `Assoc
      [ "initialized", `Bool true
      ; "cluster", `String (Env_config_core.cluster_name ())
      ; "project", `String state.project
      ; "paused", `Bool state.paused
      ; "pause_reason", Operator_pending_confirm.string_option_to_json state.pause_reason
      ; "paused_by", Operator_pending_confirm.string_option_to_json state.paused_by
      ; "paused_at", Operator_pending_confirm.string_option_to_json state.paused_at
      ; "tempo_interval_s", `Float tempo.current_interval_s
      ; "agent_count", `Int (List.length agents)
      ; "task_count", `Int (List.length tasks)
      ; "message_seq", `Int state.message_seq
      ])
;;
