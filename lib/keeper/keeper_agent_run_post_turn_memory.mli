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

    The post-turn entrypoint owns Librarian admission and its execution fence.
    Disabled or invalid configuration does not submit a Librarian unit or read
    its snapshot. An admitted asynchronous unit re-checks the live setting
    before snapshot I/O so disabling it while queued remains effective. When
    enabled, every completed conversation turn is eligible for Librarian
    extraction; the Librarian owns semantic selection rather than a scheduler-
    side external-effect heuristic. *)

module For_testing : sig
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
