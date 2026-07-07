(** Keeper_post_turn — post-turn lifecycle: compaction, handoff
    rollover, continuity summary, and overflow retry recovery.

    Orchestrates the end-of-turn pipeline that decides whether to
    compact the context, roll over to a new generation, and update
    the continuity summary from the latest state snapshot.

    This module owns only the checkpoint/lineage tail of a keeper
    turn. Memory bank append, episode flush, and Hebbian learning
    are recorded elsewhere:
    - memory bank / episodes: [Keeper_agent_run] tail after [Agent.run]
    - hebbian: task lifecycle in [Workspace_task]

    Extracted from Keeper_context_runtime as part of #4955 god-file split. *)

(** Outcome of the compaction step. [applied] iff a compaction
    strategy actually ran; [trigger] is the gate label that fired
    ([ratio]/[messages]/[tokens]). *)
type compaction_event =
  { attempted : bool
  ; applied : bool
  ; started_dispatched : bool
        (** [true] when [on_compaction_started] completed without raising,
            meaning the FSM is at [Compaction_compacting].  [false] when
            the callback failed or was never called (recovery path), so
            the FSM is still at [Compaction_accumulating]. *)
  ; failure_reason : string option
  ; trigger : Compaction_trigger.t option
  ; decision : Keeper_compact_policy.compaction_decision
  ; before_tokens : int
  ; after_tokens : int
  ; saved_tokens : int
  }

(** Combined post-turn outcome — compaction + rollover + continuity
    summary update + per-turn context metrics. *)
type post_turn_lifecycle =
  { updated_meta : Keeper_meta_contract.keeper_meta
  ; checkpoint : Agent_sdk.Checkpoint.t option
  ; handoff_json : Yojson.Safe.t option
  ; handoff_attempted : bool
  ; handoff_failure_reason : string option
  ; compaction : compaction_event
  ; turn_generation : int
  ; context_ratio : float
  ; context_tokens : int
  ; context_max : int
  ; message_count : int
  }

(** Recovered checkpoint + applied compaction event used by the
    overflow-retry flow to restart the turn from a smaller context.

    [@@warning "-69"]: declared in the .ml because not every field
    is read at the call site, but the record is exported so callers
    can match exhaustively. *)
type overflow_retry_recovery =
  { checkpoint : Agent_sdk.Checkpoint.t
  ; compaction : compaction_event
  ; turn_generation : int
  } [@@warning "-69"]

(** End-of-turn pipeline. Decides compaction, rolls over generations
    when the handoff gate fires, refreshes the continuity summary
    from the latest state snapshot, and persists the result to the
    keeper meta + dashboard surface.

    {b Tier A5} (Cycle 22): when the [MASC_AUTONOMOUS] environment
    variable is on (see {!Autonomous.Wirein_helpers.masc_autonomous_enabled}),
    the resulting [post_turn_lifecycle.checkpoint]'s working_context
    is enriched with an ["autonomous_meta"] sub-tree carrying the
    suspended {!Autonomous_bridge} state. Off-mode behaviour is
    unchanged (zero impact). *)
val apply_post_turn_lifecycle_with_resilience_handles :
  resilience_audit_store:Shared_audit.Store.t option ->
  resilience_strategy_executor:Resilience.Recovery.strategy_executor option ->
  on_compaction_started:(unit -> unit) ->
  on_handoff_started:(unit -> unit) ->
  base_dir:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  model:string ->
  primary_model_max_tokens:int ->
  current_turn_blocker_info:Keeper_meta_contract.blocker_info option ->
  checkpoint:Agent_sdk.Checkpoint.t option ->
  post_turn_lifecycle
(** Apply the keeper post-turn lifecycle with explicit resilience handles.

    Valid combinations of the two resilience arguments are:
    - both [None]: no audit envelope, no recovery side effect.
    - both [Some]: the feature-flagged resilience wire-in writes a
      durable [RecoveryAttempted] envelope through the audit store
      before invoking the executor, preserving auditability.

    Passing [resilience_strategy_executor:(Some _)] together with
    [resilience_audit_store:None] is rejected ({!Invalid_argument})
    because retry/fallback/handoff/abort callbacks would mutate
    live state without the pre-flight envelope that
    [keeper_bridge] relies on.

    @raise Invalid_argument when an executor is supplied without an
      audit store.

    Concurrency: [Shared_audit.Store.t] is a mutable single-writer
    chain ([latest_hash] + append with no internal locking).  The
    same store instance must not be threaded through concurrent
    keeper turns — sharing one across fibers can produce envelopes
    with duplicate [prev_hash] values and break audit-chain
    verification.  Callers own serialization; the typical pattern
    is one store per keeper, owned by the keeper bridge. *)

(** Build the relaxed-policy meta used during forced overflow
    retry: zero compaction gates so the next compaction always
    fires. *)
val forced_overflow_retry_meta :
  Keeper_meta_contract.keeper_meta ->
  turn_generation:int ->
  now_ts:float ->
  Keeper_meta_contract.keeper_meta

(** Reload the canonical OAS checkpoint and apply forced
    compaction so the turn can retry from a smaller context.
    Returns [None] when no checkpoint exists, when compaction did
    not actually shrink the token count, or when the recovery save
    failed. *)
val recover_latest_checkpoint_for_overflow_retry :
  base_dir:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  model:string ->
  primary_model_max_tokens:int ->
  overflow_retry_recovery option

val no_state_interruption_note : string
(** Open-question text recorded by
    {!augment_progress_with_interruption_note}. Constant so repeated
    no-[STATE] turns dedupe by membership instead of stacking. *)

val augment_progress_with_interruption_note :
  progress_path:string ->
  generation:int ->
  updated_at:string ->
  keeper_name:string ->
  unit
(** RFC-0314 P2a. Called on a turn that produced no [STATE] snapshot (the
    same turns whose checkpoint replay suffix is pruned and whose memory
    writes are suppressed): preserves the existing forward-looking
    progress.md snapshot and adds {!no_state_interruption_note} to its
    open questions, so the next turn's Continuity layer states that the
    previous turn left no persisted state instead of rendering nothing.
    Write failures are logged and counted, never raised. *)

module For_testing : sig
  val invalid_snapshot_goal_fingerprint : string -> string

  val invalid_snapshot_goal_warning_message :
    keeper_name:string -> goal_id:string -> string

  val should_log_invalid_snapshot_goal :
    keeper_name:string -> goal_id:string -> bool

  val reset_invalid_snapshot_goal_log_dedupe : unit -> unit
end
