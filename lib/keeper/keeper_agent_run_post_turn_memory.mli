(** Post-turn memory write series for [Keeper_agent_run.run_turn].

    Extracts the four post-turn side-effect stages from Step 8 body
    (deterministic write, episodic record, compaction, quality-metrics
    JSONL append) into a single typed boundary so that the orchestrator
    only sees [run ~config ~meta ...].

    Each sub-stage is best-effort: non-cancel exceptions are logged and
    counted, never propagated.  [Eio.Cancel.Cancelled] is re-raised. *)

val run :
  config:Keeper_types.config ->
  meta:Keeper_types.keeper_meta ->
  memory:Agent_sdk.Memory.t ->
  turn:int ->
  oas_turn_count:int ->
  response_text:string ->
  actual_tools:string list ->
  state_snapshot:Keeper_memory_policy.keeper_state_snapshot ->
  post_turn_t0:float ->
  ?provider_filter:string ->
  cascade_name:string ->
  inference_telemetry:Agent_sdk.Types.inference_telemetry option ->
  unit ->
  unit
(** Run the full post-turn memory series.

    [post_turn_t0] is the timestamp (from [Time_compat.now ()]) taken
    immediately before this function is called; it is used to compute
    the [post_turn_ms] metric written to the decision log.

    [inference_telemetry] is [result.response.telemetry] from the OAS
    result; it is optional because some providers do not emit telemetry. *)
