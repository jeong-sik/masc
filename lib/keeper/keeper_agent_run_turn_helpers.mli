(** Small helpers used by [Keeper_agent_run.run_turn]. *)

val mark_task_link : keeper:string -> task_id:string -> trace_id:string -> unit

val task_link_already_recorded :
  keeper:string -> task_id:string -> trace_id:string -> bool

val per_provider_timeout_for_turn :
  meta:Keeper_types.keeper_meta ->
  ?oas_timeout_s:float ->
  ?oas_timeout_is_explicit:bool ->
  timeout_s:float ->
  unit ->
  float option

val sse_event_progress_kind : Agent_sdk.Types.sse_event -> string option

val registry_progress_on_event :
  record_turn_progress:(string -> unit) ->
  (Agent_sdk.Types.sse_event -> unit) option ->
  Agent_sdk.Types.sse_event ->
  unit

val select_cdal_proof :
  result_proof:Masc_mcp_cdal_runtime.Cdal_proof.t option ->
  captured_proof:Masc_mcp_cdal_runtime.Cdal_proof.t option ->
  Masc_mcp_cdal_runtime.Cdal_proof.t option

val should_require_provider_tool_choice_support :
  initial_tool_requirement:Keeper_agent_tool_surface.tool_requirement ->
  actionable_observation_requires_tool_support:bool ->
  bool

val tool_contract_result_for_observed_tools :
  required_tool_names:string list ->
  missing_visible_required:string list ->
  had_owned_active_task_at_turn_start:bool ->
  actual_keeper_tool_names:string list ->
  Keeper_execution_receipt.tool_contract_result

val emit_turn_end_safely : keeper_name:string -> unit -> unit
val digest_text : string -> string
val digest_message_texts_as_joined : Agent_sdk.Types.message list -> string

val runtime_manifest_context :
  keeper_name:string ->
  agent_name:string ->
  trace_id:string ->
  generation:int ->
  keeper_turn_id:int ->
  Keeper_runtime_manifest.turn_context

val append_runtime_manifest :
  config:Coord.config ->
  keeper_name:string ->
  agent_name:string ->
  trace_id:string ->
  generation:int ->
  cascade_name:string ->
  ?status:string ->
  ?decision:Yojson.Safe.t ->
  ?keeper_turn_id:int ->
  ?oas_turn_count:int ->
  ?checkpoint_path:string ->
  ?receipt_path:string ->
  site:string ->
  Keeper_runtime_manifest.event_kind ->
  unit

val cleanup_agent_setup :
  keeper_name:string -> Keeper_run_tools.agent_setup -> unit

val run_with_setup_cleanup : cleanup:(unit -> unit) -> (unit -> 'a) -> 'a

val turn_progress_callbacks :
  config:Coord.config ->
  keeper_name:string ->
  downstream:(Agent_sdk.Types.sse_event -> unit) option ->
  (string -> unit)
  * bool
  * (unit -> unit) option
  * (unit -> unit) option
  * (Agent_sdk.Types.sse_event -> unit) option
