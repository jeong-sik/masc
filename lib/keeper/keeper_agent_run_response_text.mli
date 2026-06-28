(** Response text and [STATE] snapshot finalization for keeper agent runs. *)

type finalized = {
  state_snapshot : Keeper_memory_policy.keeper_state_snapshot;
  state_snapshot_source : Keeper_memory_policy.state_snapshot_source;
  response_text : string;
}

val stop_reason_label : Runtime_agent.stop_reason -> string

val stop_reason_is_turn_budget_exhausted : Runtime_agent.stop_reason -> bool

val finalize :
  reported_state_snapshot:Keeper_memory_policy.keeper_state_snapshot option ->
  keeper_name:string ->
  goal:string ->
  actual_keeper_tool_names:string list ->
  stop_reason:Runtime_agent.stop_reason ->
  raw_response_text:string ->
  unit ->
  finalized
