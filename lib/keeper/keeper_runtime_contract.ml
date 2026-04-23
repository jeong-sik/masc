open Keeper_types

let current_task_id_opt (meta : keeper_meta) =
  Option.map Keeper_id.Task_id.to_string meta.current_task_id

let primary_goal_id_opt (meta : keeper_meta) =
  match meta.active_goal_ids with
  | goal_id :: _ -> Some goal_id
  | [] -> None

let backend_of_meta (meta : keeper_meta) =
  match meta.sandbox_profile with
  | Docker -> "docker"
  | Local -> "local"

let task_is_linked_to_keeper_goals goal_ids (task : Types.task) =
  List.exists
    (fun goal_id -> Convergence.task_matches_goal ~goal_id task)
    goal_ids

let task_is_blocked (task : Types.task) =
  match task.task_status with
  | Types.AwaitingVerification _ -> true
  | _ -> false

let goal_progress_json ?config (meta : keeper_meta) =
  match config with
  | None ->
      `Assoc
        [
          ("active_goal_count", `Int (List.length meta.active_goal_ids));
          ("linked_task_count", `Int 0);
          ("done_task_count", `Int 0);
          ("open_task_count", `Int 0);
          ("blocked_task_count", `Int 0);
          ("convergence", `Null);
        ]
  | Some config ->
      let tasks =
        Coord.get_tasks_safe config
        |> List.filter (task_is_linked_to_keeper_goals meta.active_goal_ids)
      in
      let linked_task_count = List.length tasks in
      let done_task_count =
        List.fold_left
          (fun acc (task : Types.task) ->
            if Types.task_status_is_done task.task_status then acc + 1 else acc)
          0 tasks
      in
      let open_task_count =
        List.fold_left
          (fun acc (task : Types.task) ->
            if Types.task_status_is_terminal task.task_status then acc else acc + 1)
          0 tasks
      in
      let blocked_task_count =
        List.fold_left
          (fun acc (task : Types.task) ->
            if task_is_blocked task then acc + 1 else acc)
          0 tasks
      in
      let convergence =
        if linked_task_count = 0 then `Null
        else `Float (float_of_int done_task_count /. float_of_int linked_task_count)
      in
      `Assoc
        [
          ("active_goal_count", `Int (List.length meta.active_goal_ids));
          ("linked_task_count", `Int linked_task_count);
          ("done_task_count", `Int done_task_count);
          ("open_task_count", `Int open_task_count);
          ("blocked_task_count", `Int blocked_task_count);
          ("convergence", convergence);
        ]

let approval_policy_effective_json ?config (meta : keeper_meta) =
  let base_path =
    match config with
    | Some (config : Coord.config) -> config.base_path
    | None -> Env_config_core.base_path ()
  in
  Keeper_approval_queue.policy_summary_json ~base_path ~keeper_name:meta.name

let runtime_contract_json ?config (meta : keeper_meta) : Yojson.Safe.t =
  let sandbox_target = backend_of_meta meta in
  let goal_progress = goal_progress_json ?config meta in
  let blocked_task_count =
    Safe_ops.json_int "blocked_task_count" ~default:0 goal_progress
  in
  `Assoc
    [
      ("sandbox_profile", `String (sandbox_profile_to_string meta.sandbox_profile));
      ("network_mode", `String (network_mode_to_string meta.network_mode));
      ( "shared_memory_scope",
        `String (shared_memory_scope_to_string meta.shared_memory_scope) );
      ("backend", `String sandbox_target);
      ("sandbox_target", `String sandbox_target);
      ("task_id", Json_util.string_opt_to_json (current_task_id_opt meta));
      ("goal_id", Json_util.string_opt_to_json (primary_goal_id_opt meta));
      ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids));
      ("goal_progress", goal_progress);
      ("blocked_task_count", `Int blocked_task_count);
      ("approval_policy_effective", approval_policy_effective_json ?config meta);
    ]
