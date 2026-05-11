(** Keeper_agent_checkpoint_hygiene — pre-dispatch checkpoint hygiene.

    Runs once per turn before dispatching to {!Agent_sdk.Agent.run}: applies
    the compaction policy with [cooldown_sec=0] (a forced one-shot
    evaluation distinct from the regular cooldown-gated policy), then
    resolves the resume checkpoint slot.  Extracted from
    {!Keeper_agent_run} so the compaction-policy evaluation can be
    tested without driving the full turn pipeline. *)

type pre_dispatch_checkpoint_hygiene_result = {
  context : Keeper_types.working_context;
  resume_checkpoint : Agent_sdk.Checkpoint.t option;
  compacted : bool;
  (** Equal to [applied].  Kept for surface clarity at call sites. *)
  applied : bool;
  meaningful_reduction : bool;
  (** [after_tokens < before_tokens].  Used to suppress no-op
      compaction logs. *)
  before_tokens : int;
  after_tokens : int;
  trigger : Compaction_trigger.t option;
  (** [Some _] when {!Keeper_compact_policy.compact_if_needed_typed}
      classified a trigger; [None] when no compaction fired.  Use
      {!Compaction_trigger.to_label} for Prometheus emission and
      {!Compaction_trigger.to_detail_json} for SSE / JSON receipt. *)
  decision : Keeper_compact_policy.compaction_decision;
  (** Typed decision tag from the policy. Render with
      {!Keeper_compact_policy.compaction_decision_to_string} at telemetry
      boundaries. *)
  save_error : string option;
  (** [Some err] when the checkpoint save attempt failed.  The
      working context is still populated from the compacted one. *)
}

val prepare_resume_checkpoint_for_dispatch :
  meta:Keeper_types.keeper_meta ->
  now_ts:float ->
  loaded_checkpoint_present:bool ->
  save_checkpoint:
    (Keeper_types.working_context ->
    (Agent_sdk.Checkpoint.t, string) result) ->
  Keeper_types.working_context ->
  pre_dispatch_checkpoint_hygiene_result
(** [prepare_resume_checkpoint_for_dispatch ~meta ~now_ts
    ~loaded_checkpoint_present ~save_checkpoint ctx]:

    1. Forces a fresh compaction evaluation by overriding
       [meta.compaction.cooldown_sec] to [0].
       The evaluation is scoped to restored checkpoint/history state.
       Fresh turn substrate such as the system prompt, tool catalog, and
       current user assignment is measured by wake-payload telemetry but
       is not checkpoint history that this function can compact.
    2. Calls {!Keeper_compact_policy.compact_if_needed_typed}; populates
       [before_tokens] / [after_tokens] / [trigger] / [decision] from
       the result.
    3. When [loaded_checkpoint_present] is [false], skips checkpoint
       resolution entirely — the dispatch starts a fresh OAS run.
    4. When checkpoint resolution is required and compaction did
       fire, calls [save_checkpoint] to persist the compacted state.
       On save failure the result carries no resume checkpoint, and
       [save_error] surfaces the detail so the caller can block dispatch.
    5. When no compaction fired, returns the derived checkpoint of
       the unchanged context. *)
