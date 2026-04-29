(** Keeper_agent_checkpoint_hygiene — pre-dispatch checkpoint hygiene.

    Runs once per turn before dispatching to {!Oas.Agent.run}: applies
    the compaction policy with [cooldown_sec=0] (a forced one-shot
    evaluation distinct from the regular cooldown-gated policy), then
    resolves the resume checkpoint slot.  Extracted from
    {!Keeper_agent_run} so the compaction-policy evaluation can be
    tested without driving the full turn pipeline. *)

type pre_dispatch_checkpoint_hygiene_result = {
  context : Keeper_types.working_context;
  resume_checkpoint : Oas.Checkpoint.t option;
  compacted : bool;
  (** Equal to [applied].  Kept for surface clarity at call sites. *)
  applied : bool;
  meaningful_reduction : bool;
  (** [after_tokens < before_tokens].  Used to suppress no-op
      compaction logs. *)
  before_tokens : int;
  after_tokens : int;
  trigger : string option;
  (** [Some _] when {!Keeper_compact_policy.compact_if_needed}
      identified a trigger; [None] when no compaction fired. *)
  decision : string;
  (** Human-readable decision tag from the policy ([no_op],
      [hard_cap], etc.) for telemetry. *)
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
    (Oas.Checkpoint.t, string) result) ->
  Keeper_types.working_context ->
  pre_dispatch_checkpoint_hygiene_result
(** [prepare_resume_checkpoint_for_dispatch ~meta ~now_ts
    ~loaded_checkpoint_present ~save_checkpoint ctx]:

    1. Forces a fresh compaction evaluation by overriding
       [meta.compaction.cooldown_sec] to [0].
    2. Calls {!Keeper_compact_policy.compact_if_needed}; populates
       [before_tokens] / [after_tokens] / [trigger] / [decision] from
       the result.
    3. When [loaded_checkpoint_present] is [false], skips checkpoint
       resolution entirely — the dispatch starts a fresh OAS run.
    4. When checkpoint resolution is required and compaction did
       fire, calls [save_checkpoint] to persist the compacted state.
       On save failure the result still carries a derived checkpoint
       so the dispatch is not blocked, and [save_error] surfaces the
       detail for observability.
    5. When no compaction fired, returns the derived checkpoint of
       the unchanged context. *)
