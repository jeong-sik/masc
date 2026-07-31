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
  generation:int ->
  profile_defaults:Keeper_types_profile.keeper_profile_defaults ->
  turn:int ->
  oas_turn_count:int ->
  actual_tools:string list ->
  librarian_messages:Agent_sdk.Types.message list ->
  turn_effect_record:Keeper_run_prompt.turn_effect_record ->
  post_turn_t0:float ->
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

    [profile_defaults] feeds the persona-name resolution shared with the
    keeper's own system prompt
    ([Keeper_types_profile.load_resolved_persona_extended]); the resolved
    persona text rides the Librarian input so curation judges importance
    through the keeper's identity.

    [deliberation_execution], when available, is persisted as advisory
    delegation request artifacts on this post-turn memory lane rather than on
    the decision-record append path.

    The post-turn entrypoint owns Librarian admission and its execution fence.
    Disabled or invalid configuration does not submit a Librarian unit or read
    its snapshot. An admitted asynchronous unit re-checks the live setting
    before snapshot I/O so disabling it while queued remains effective. When
    enabled, [turn_effect_record] admits only [Meaningful_turn]; on
    [Inert_autonomous_turn] the librarian unit is never submitted, so its
    cadence counter does not advance and an idle stretch spends no extraction
    budget.
    The deterministic write series runs either way: a model-owned
    [keeper_memory_write] on an otherwise inert turn is an explicit decision to
    remember, not an extraction from prose. *)
