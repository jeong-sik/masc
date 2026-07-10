(** Post-turn memory write series for [Keeper_agent_run.run_turn].

    Extracts the four post-turn side-effect stages from Step 8 body
    (deterministic write, episodic record, compaction, quality-metrics
    JSONL append) into a single typed boundary so that the orchestrator
    only sees [run ~config ~meta ...].

    Each sub-stage is best-effort: non-cancel exceptions are logged and
    counted, never propagated.  [Eio.Cancel.Cancelled] is re-raised. *)

val run :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  generation:int ->
  turn:int ->
  oas_turn_count:int ->
  response_text:string ->
  actual_tools:string list ->
  librarian_messages:Agent_sdk.Types.message list ->
  post_turn_t0:float ->
  runtime_id:string ->
  inference_telemetry:Agent_sdk.Types.inference_telemetry option ->
  ?deliberation_execution:Keeper_deliberation.execution_result ->
  unit ->
  unit
(** Run the full post-turn memory series.

    [post_turn_t0] is the timestamp (from [Time_compat.now ()]) taken
    immediately before this function is called; it is used to compute
    the [post_turn_ms] metric written to the decision log.

    [inference_telemetry] is [result.response.telemetry] from the OAS
    result; it is optional because some providers do not emit telemetry.

    [deliberation_execution], when available, is persisted as advisory
    delegation request artifacts on this post-turn memory lane rather than on
    the decision-record append path. *)
