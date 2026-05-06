val current_task_id_opt : Keeper_types.keeper_meta -> string option
val primary_goal_id_opt : Keeper_types.keeper_meta -> string option
val backend_of_meta : Keeper_types.keeper_meta -> string
val task_is_linked_to_keeper_goals :
  string list -> Masc_domain.task -> bool

type claim_goal_scope = {
  task_filter : Masc_domain.task -> bool;
  mode : string;
  effective_goal_ids : string list;
  fallback_reason : string option;
}

val resolve_claim_goal_scope :
  ?agent_tool_names:string list ->
  (** [allow_empty_goal_scope_fallback] should stay false for normal keeper
      task claims. Auto-repaired keeper-purpose goals may still fall back to
      all tasks; explicit persisted [active_goal_ids] stay scoped unless this
      flag is set. *)
  ?allow_empty_goal_scope_fallback:bool ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  unit ->
  claim_goal_scope

val runtime_contract_json :
  ?config:Coord.config -> Keeper_types.keeper_meta -> Yojson.Safe.t

val runtime_contract_json_from_fields :
  keeper_name:string ->
  ?agent_name:string ->
  ?trace_id:string ->
  ?session_id:string ->
  ?generation:int ->
  ?keeper_turn_id:int ->
  ?task_id:string ->
  ?goal_ids:string list ->
  ?sandbox_profile:string ->
  ?sandbox_root:string ->
  ?allowed_paths:string list ->
  ?network_mode:string ->
  ?approval_mode:string ->
  ?tool_surface_class:string ->
  ?visible_tool_count:int ->
  ?required_tools:string list ->
  ?missing_required_tools:string list ->
  ?provider:string ->
  ?model:string ->
  ?cascade_profile:string ->
  unit ->
  Yojson.Safe.t

val action_radius_json :
  tool_name:string ->
  input:Yojson.Safe.t ->
  success:bool ->
  duration_ms:float ->
  ?error:string ->
  ?sandbox_target:string ->
  unit ->
  Yojson.Safe.t
