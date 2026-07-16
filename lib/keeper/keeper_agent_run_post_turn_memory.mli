(** Post-turn memory write series for [Keeper_agent_run.run_turn].

    Extracts deterministic writes, LLM librarian records, and quality metrics
    from Step 8 behind [run ~config ~meta ...]. It does not rewrite or delete
    memory-bank rows: semantic consolidation requires an explicit typed LLM
    Memory operation, never a storage-pressure survival rule.

    Memory work is durably admitted before the owner lane is signalled. *)

val schedule_drain
  :  base_path:string
  -> keeper_name:string
  -> (unit, Keeper_memory_lane.admission_error) result
(** Signal the per-Keeper owner lane to drain already-durable Memory work. *)

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

    [deliberation_execution], when available, is persisted at the separate
    delegation artifact boundary. *)
