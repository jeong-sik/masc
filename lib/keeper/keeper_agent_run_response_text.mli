(** Response text and [STATE] snapshot finalization for keeper agent runs. *)

type finalized = {
  state_snapshot : Keeper_memory_policy.keeper_state_snapshot;
  response_text : string;
}

val stop_reason_label : Cascade_runner.stop_reason -> string

val finalize :
  keeper_name:string ->
  goal:string ->
  actual_keeper_tool_names:string list ->
  fallback_tool_names:string list ->
  stop_reason:Cascade_runner.stop_reason ->
  raw_response_text:string ->
  finalized
