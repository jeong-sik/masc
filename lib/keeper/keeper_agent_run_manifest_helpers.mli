(** Runtime-manifest append helpers for {!Keeper_agent_run}. *)

type append_manifest =
  ?status:string ->
  ?decision:Yojson.Safe.t ->
  ?keeper_turn_id:int ->
  ?oas_turn_count:int ->
  ?checkpoint_path:string ->
  ?receipt_path:string ->
  site:string ->
  Keeper_runtime_manifest.event_kind ->
  unit

val append_checkpoint_start_events :
  append_manifest:append_manifest ->
  keeper_turn_id:int ->
  checkpoint_path:string ->
  loaded_checkpoint_present:bool ->
  pre_dispatch_compacted:bool ->
  pre_dispatch_checkpoint_error:Agent_sdk.Error.sdk_error option ->
  unit

val append_context_injected :
  append_manifest:append_manifest ->
  keeper_turn_id:int ->
  base_system_prompt:string ->
  turn_system_prompt:string ->
  dynamic_context:string ->
  memory_context:string ->
  temporal_context:string ->
  user_message:string ->
  history_messages:Agent_sdk.Types.message list ->
  estimated_input_tokens:int ->
  unit

val append_tool_surface_selected :
  append_manifest:append_manifest ->
  keeper_turn_id:int ->
  Keeper_agent_tool_surface.tool_surface_metrics ->
  unit
