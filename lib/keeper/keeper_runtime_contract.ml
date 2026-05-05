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

let task_is_linked_to_keeper_goals goal_ids (task : Masc_domain.task) =
  List.exists
    (fun goal_id -> Convergence.task_matches_goal ~goal_id task)
    goal_ids

type claim_goal_scope = {
  task_filter : Masc_domain.task -> bool;
  mode : string;
  effective_goal_ids : string list;
  fallback_reason : string option;
}

let goal_title_matches_keeper_purpose ~(meta : keeper_meta) goal =
  String.equal goal.Goal_store.title
    (Keeper_goal_repair.goal_title_of_purpose meta.goal)

let active_goal_ids_are_auto_keeper_goals config ~(meta : keeper_meta) goal_ids =
  goal_ids <> []
  && List.for_all
       (fun goal_id ->
         match Goal_store.get_goal config ~goal_id with
         | Some goal -> goal_title_matches_keeper_purpose ~meta goal
         | None -> false)
       goal_ids

let task_is_eligible_for_claim ?agent_tool_names latest_verification_status task =
  Coord_task_schedule.task_is_claim_pool_candidate task
  && not
       (Coord_task_schedule.verification_blocks_claim
          latest_verification_status
          task)
  && Coord_task_schedule.required_tools_allowed
       ?agent_tool_names
       (Coord_task_schedule.task_required_tools task)

let active_goal_ids_have_eligible_claim_task
    ?agent_tool_names
    config
    goal_ids
  =
  let latest_verification_status =
    Coord_task_schedule.latest_verification_status_by_task config
  in
  Coord.get_tasks_safe config
  |> List.exists (fun task ->
       task_is_linked_to_keeper_goals goal_ids task
       && task_is_eligible_for_claim
            ?agent_tool_names
            latest_verification_status
            task)

let resolve_claim_goal_scope ?agent_tool_names ~(config : Coord.config)
    ~(meta : keeper_meta) =
  match meta.active_goal_ids with
  | [] ->
      {
        task_filter = (fun (_task : Masc_domain.task) -> true);
        mode = "all_tasks";
        effective_goal_ids = [];
        fallback_reason = None;
      }
  | goal_ids ->
      let scoped_filter task = task_is_linked_to_keeper_goals goal_ids task in
      if
        not
          (active_goal_ids_have_eligible_claim_task
             ?agent_tool_names
             config
             goal_ids)
      then
        let is_auto_goal =
          active_goal_ids_are_auto_keeper_goals config ~meta goal_ids
        in
        {
          task_filter = (fun (_task : Masc_domain.task) -> true);
          mode =
            (if is_auto_goal then "auto_goal_fallback_all_tasks"
             else "empty_goal_scope_fallback_all_tasks");
          effective_goal_ids = [];
          fallback_reason =
            Some
              (if is_auto_goal then
                 "auto keeper goal has no claimable linked tasks; falling back to all claimable tasks"
               else
                 "active goal scope has no claimable linked tasks; falling back to all claimable tasks");
        }
      else
        {
          task_filter = scoped_filter;
          mode = "active_goal_ids";
          effective_goal_ids = goal_ids;
          fallback_reason = None;
        }

let task_is_blocked (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.AwaitingVerification _ -> true
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
          (fun acc (task : Masc_domain.task) ->
            if Masc_domain.task_status_is_done task.task_status then acc + 1 else acc)
          0 tasks
      in
      let open_task_count =
        List.fold_left
          (fun acc (task : Masc_domain.task) ->
            if Masc_domain.task_status_is_terminal task.task_status then acc else acc + 1)
          0 tasks
      in
      let blocked_task_count =
        List.fold_left
          (fun acc (task : Masc_domain.task) ->
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

let string_opt_json = function
  | Some value when String.trim value <> "" -> `String value
  | _ -> `Null

let int_opt_json = function
  | Some value -> `Int value
  | None -> `Null

let string_list_json values =
  `List (List.map (fun value -> `String value) values)

let nonempty_list = function
  | Some values -> values
  | None -> []

let provider_of_model = function
  | None -> None
  | Some model -> (
      let model = String.trim model in
      if model = "" then None
      else
        match String.index_opt model ':' with
        | Some idx when idx > 0 -> Some (String.sub model 0 idx)
        | _ -> None)

let runtime_contract_json_from_fields ~keeper_name ?agent_name ?trace_id
    ?session_id ?generation ?keeper_turn_id ?task_id ?goal_ids
    ?sandbox_profile ?sandbox_root ?allowed_paths ?network_mode ?approval_mode ?tool_surface_class
    ?visible_tool_count ?required_tools ?missing_required_tools ?provider ?model
    ?cascade_profile () : Yojson.Safe.t =
  let provider =
    match provider with
    | Some _ -> provider
    | None -> provider_of_model model
  in
  `Assoc
    [
      ("keeper_name", `String keeper_name);
      ("agent_name", string_opt_json agent_name);
      ("trace_id", string_opt_json trace_id);
      ("session_id", string_opt_json session_id);
      ("generation", int_opt_json generation);
      ("keeper_turn_id", int_opt_json keeper_turn_id);
      ("task_id", string_opt_json task_id);
      ("goal_ids", string_list_json (nonempty_list goal_ids));
      ("sandbox_profile", string_opt_json sandbox_profile);
      ("sandbox_root", string_opt_json sandbox_root);
      ("allowed_paths", string_list_json (nonempty_list allowed_paths));
      ("network_mode", string_opt_json network_mode);
      ("approval_mode", string_opt_json approval_mode);
      ("tool_surface_class", string_opt_json tool_surface_class);
      ("visible_tool_count", int_opt_json visible_tool_count);
      ("required_tools", string_list_json (nonempty_list required_tools));
      ( "missing_required_tools",
        string_list_json (nonempty_list missing_required_tools) );
      ("provider", string_opt_json provider);
      ("model", string_opt_json model);
      ("cascade_profile", string_opt_json cascade_profile);
    ]

let contains_substring haystack needle =
  String_util.contains_substring haystack needle

let json_string_field name json = Json_util.get_string_nonempty json name

let first_string_field names json =
  List.find_map (fun name -> json_string_field name json) names

let path_like_key key =
  let key = String.lowercase_ascii key in
  key = "cwd" || key = "dir" || key = "directory" || key = "file"
  || contains_substring key "path"

let collect_observed_paths json =
  let rec loop acc = function
    | `Assoc fields ->
        List.fold_left
          (fun acc (key, value) ->
            match value with
            | `String path when path_like_key key && String.trim path <> "" ->
                path :: acc
            | other -> loop acc other)
          acc fields
    | `List values -> List.fold_left loop acc values
    | _ -> acc
  in
  loop [] json
  |> List.sort_uniq String.compare

let target_kind_of_input input target_path =
  match json_string_field "target_kind" input with
  | Some value -> value
  | None -> (
      match json_string_field "kind" input with
      | Some value -> value
      | None -> (
          match target_path with
          | Some _ -> "path"
          | None -> "tool"))

let action_radius_json ~tool_name ~input ~success ~duration_ms ?error
    ?sandbox_target () : Yojson.Safe.t =
  let action_key =
    first_string_field [ "action"; "action_key"; "op"; "cmd"; "command" ] input
    |> Option.value ~default:tool_name
  in
  let target_path =
    first_string_field
      [
        "target_path";
        "path";
        "file_path";
        "repo_path";
        "worktree_path";
        "cwd";
      ]
      input
  in
  `Assoc
    [
      ("tool_name", `String tool_name);
      ("action_key", `String action_key);
      ("target_kind", `String (target_kind_of_input input target_path));
      ("target_path", string_opt_json target_path);
      ("sandbox_target", string_opt_json sandbox_target);
      ("observed_paths", string_list_json (collect_observed_paths input));
      ("success", `Bool success);
      ("duration_ms", `Float duration_ms);
      ("error", string_opt_json error);
    ]

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
      ("backend", `String sandbox_target);
      ("sandbox_target", `String sandbox_target);
      ("task_id", Json_util.string_opt_to_json (current_task_id_opt meta));
      ("goal_id", Json_util.string_opt_to_json (primary_goal_id_opt meta));
      ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids));
      ("goal_progress", goal_progress);
      ("blocked_task_count", `Int blocked_task_count);
      ("approval_policy_effective", approval_policy_effective_json ?config meta);
    ]
