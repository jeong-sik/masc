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

let runtime_contract_json (meta : keeper_meta) : Yojson.Safe.t =
  `Assoc
    [
      ( "execution_scope",
        `String (Keeper_execution_scope.to_string meta.execution_scope) );
      ("sandbox_profile", `String (sandbox_profile_to_string meta.sandbox_profile));
      ("network_mode", `String (network_mode_to_string meta.network_mode));
      ( "shared_memory_scope",
        `String (shared_memory_scope_to_string meta.shared_memory_scope) );
      ("backend", `String (backend_of_meta meta));
      ("task_id", Json_util.string_opt_to_json (current_task_id_opt meta));
      ("goal_id", Json_util.string_opt_to_json (primary_goal_id_opt meta));
      ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids));
    ]
