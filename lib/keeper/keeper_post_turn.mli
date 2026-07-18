(** Keeper_post_turn — post-turn checkpoint preservation, handoff rollover,
    and explicit compaction recovery.

    Orchestrates end-of-turn checkpoint wire-ins. Compaction is never inferred
    here; manual and provider-overflow callers enter the explicit recovery
    function with a typed trigger.

    This module owns only the checkpoint/lineage tail of a keeper
    turn. Memory bank append, episode flush, and Hebbian learning
    are recorded elsewhere:
    - memory bank / episodes: [Keeper_agent_run] tail after [Agent.run]
    - hebbian: task lifecycle in [Workspace_task]

    Extracted from Keeper_context_runtime as part of #4955 god-file split. *)

(** Combined post-turn outcome for checkpoint preservation, rollover, and
    per-turn context metrics. Explicit compaction has its own request path. *)
type post_turn_lifecycle =
  { updated_meta : Keeper_meta_contract.keeper_meta
  ; checkpoint : Agent_sdk.Checkpoint.t option
  ; handoff_json : Yojson.Safe.t option
  ; handoff_attempted : bool
  ; handoff_failure_reason : string option
  ; turn_generation : int
  ; checkpoint_bytes : int
  ; message_count : int
  }

(** Recovered checkpoint after a durably applied explicit compaction request.
    Manual and provider-overflow callers consume the same result. *)
type compaction_recovery =
  { checkpoint : Agent_sdk.Checkpoint.t
  ; trigger : Compaction_trigger.t
  ; evidence : Keeper_compaction_evidence.t
  ; turn_generation : int
  } [@@warning "-69"]

type compaction_recovery_error =
  | Checkpoint_ref_load_failed of Keeper_checkpoint_store.checkpoint_ref_load_error
  | Checkpoint_cas_failed of Keeper_checkpoint_store.checkpoint_cas_error
  | Checkpoint_structure_invalid of Keeper_compaction_unit.structural_error
  | Checkpoint_candidate_failed of string
  | Compaction_rejected of Keeper_compact_policy.compaction_rejection
  | Compaction_evidence_missing
  | Unexpected_compaction_decision of Keeper_compact_policy.compaction_decision

val compaction_recovery_error_to_tag : compaction_recovery_error -> string
val compaction_recovery_error_to_string : compaction_recovery_error -> string

(** End-of-turn pipeline. Preserves the checkpoint and persists the result to
    the keeper meta and dashboard surface. Explicit compaction is a separate
    request path; Keeper autonomy remains owned by its heartbeat/turn lane. *)
val apply_post_turn_lifecycle_with_resilience_handles :
  resilience_audit_store:Shared_audit.Store.t option ->
  resilience_strategy_executor:Resilience.Recovery.strategy_executor option ->
  meta:Keeper_meta_contract.keeper_meta ->
  primary_model_max_tokens:int ->
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
    compaction request. Returns success only after a structurally changed
    [Prepared] candidate has been durably saved; every other outcome is a
    typed [Error]. *)
val recover_latest_checkpoint_for_compaction :
  base_dir:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  trigger:Compaction_trigger.t ->
  primary_model_max_tokens:int ->
  (compaction_recovery, compaction_recovery_error) result
