(** Keeper_post_turn — post-turn lifecycle: compaction, handoff
    rollover, and overflow retry recovery.

    Orchestrates the end-of-turn pipeline that decides whether to
    compact the context and roll over to a new generation.

    This module owns only the checkpoint/lineage tail of a keeper
    turn. Memory bank append, episode flush, and Hebbian learning
    are recorded elsewhere:
    - memory bank / episodes: [Keeper_agent_run] tail after [Agent.run]
    - hebbian: task lifecycle in [Workspace_task]

    Extracted from Keeper_context_runtime as part of #4955 god-file split. *)

(** Outcome of the compaction step. [applied] iff an explicit compaction
    request ran. *)
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
  }

(** Combined post-turn outcome — compaction + rollover + per-turn context
    metrics. *)
type post_turn_lifecycle =
  { updated_meta : Keeper_meta_contract.keeper_meta
  ; checkpoint : Agent_sdk.Checkpoint.t option
  ; handoff_json : Yojson.Safe.t option
  ; handoff_attempted : bool
  ; handoff_failure_reason : string option
  ; compaction : compaction_event
  ; turn_generation : int
  ; checkpoint_bytes : int
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
  ; evidence : Keeper_compact_policy.compaction_evidence
  ; turn_generation : int
  } [@@warning "-69"]

type compaction_recovery_error =
  | Checkpoint_load_failed of Keeper_checkpoint_store.checkpoint_load_error
  | Compaction_rejected of Keeper_compact_policy.compaction_rejection
  | Compaction_evidence_missing
  | Unexpected_compaction_decision of Keeper_compact_policy.compaction_decision
  | Checkpoint_superseded of
      { incoming_turn_count : int
      ; known_turn_count : int
      }
  | Checkpoint_save_failed of string

val compaction_recovery_error_to_tag : compaction_recovery_error -> string
val compaction_recovery_error_to_string : compaction_recovery_error -> string

(** End-of-turn pipeline. Preserves the checkpoint and persists the result to
    the keeper meta and dashboard surface. Explicit compaction is a separate
    request path. Keeper autonomy is owned by the per-Keeper heartbeat/turn
    lane; this pipeline does not run a second autonomous state machine. *)
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

(** Reload the canonical OAS checkpoint and apply an explicit typed
    compaction request. Returns a durably saved [Applied] checkpoint only for a
    structurally changed [Prepared] candidate; every other outcome is a typed
    [Error]. *)
val recover_latest_checkpoint_for_overflow_retry :
  base_dir:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  trigger:Compaction_trigger.t ->
  primary_model_max_tokens:int ->
  (overflow_retry_recovery, compaction_recovery_error) result

module For_testing : sig
  (** Promote a structurally [Prepared] trigger only after [save] reports an
      actual durable write. Callers with a classified store result must not
      map a stale no-op to [Ok]. *)
  val commit_prepared_after_save :
    trigger:Compaction_trigger.t ->
    save:(unit -> ('checkpoint, 'error) result) ->
    ( 'checkpoint * Keeper_compact_policy.compaction_decision
    , 'error )
    result
end
