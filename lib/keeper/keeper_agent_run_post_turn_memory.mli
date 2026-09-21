(** Post-turn memory write series for [Keeper_agent_run.run_turn].

    Extracts deterministic writes, LLM current-memory selection, and quality metrics
    from Step 8 behind [run ~config ~meta ...]. It does not rewrite or delete
    durable Memory OS records: semantic supersession requires a separate,
    explicit typed Memory operation, never a storage-pressure survival rule.

    Each sub-stage is best-effort: non-cancel exceptions are logged and
    counted, never propagated.  [Eio.Cancel.Cancelled] is re-raised. *)

val run :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  turn:int ->
  agent_core_turn_count:int ->
  tool_observations:Keeper_librarian.tool_observation list ->
  librarian_messages:Agent_core.Types.message list ->
  checkpoint_owner:Runtime_execution.checkpoint_owner ->
  post_turn_t0:float ->
  inference_telemetry:Agent_core.Types.inference_telemetry option ->
  unit ->
  unit
(** Run the full post-turn memory series.

    [post_turn_t0] is the timestamp (from [Time_compat.now ()]) taken
    immediately before this function is called. It fences asynchronous
    counterpart evidence so a later turn is not admitted into this Librarian
    unit, and starts the [post_turn_ms] metric written to the decision log.

    [inference_telemetry] is [result.response.telemetry] from the AGENT_CORE
    result; it is optional because some providers do not emit telemetry.

    Agent-Core turns wake the durable consumer after the checkpoint boundary
    is stored and discard any remembered direct closure. Official-client turns
    retain the direct input path until they have a durable history source.
    Disabled or invalid configuration submits neither path. *)

module For_testing : sig
  val goal_context_for_task :
    config:Workspace.config ->
    Keeper_id.Task_id.t option ->
    Keeper_librarian.goal_context

  val counterpart_observations_before :
    base_dir:string ->
    keeper_name:string ->
    before:float ->
    Keeper_counterpart_observation.t list

  val counterpart_observations_before_offloaded :
    base_dir:string ->
    keeper_name:string ->
    before:float ->
    Keeper_counterpart_observation.t list
end
