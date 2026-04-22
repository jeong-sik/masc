val current_task_id_opt : Keeper_types.keeper_meta -> string option
val primary_goal_id_opt : Keeper_types.keeper_meta -> string option
val backend_of_meta : Keeper_types.keeper_meta -> string
val runtime_contract_json : Keeper_types.keeper_meta -> Yojson.Safe.t
