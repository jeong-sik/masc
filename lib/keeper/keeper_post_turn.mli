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
  ; checkpoint_installation : Keeper_checkpoint_store.checkpoint_installation
  ; trigger : Compaction_trigger.t
  ; evidence : Keeper_compaction_evidence.t
  ; turn_generation : int
  } [@@warning "-69"]

type no_compaction = Keeper_event_queue_state.no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : Keeper_event_queue_state.no_compaction_reason
  }

type compaction_recovery_error =
  | Checkpoint_ref_load_failed of Keeper_checkpoint_store.checkpoint_ref_load_error
  | Checkpoint_cas_failed of Keeper_checkpoint_store.checkpoint_cas_error
  | Checkpoint_candidate_failed of string
  | Compaction_rejected of Keeper_compact_policy.compaction_rejection
  | No_compaction of no_compaction
  | Retry_suspended of { consecutive_failures : int }
      (** RFC-0351 S0 / #25461: the keeper's compaction failure streak reached
          [Keeper_meta_contract.compaction_retry_escalation_threshold], so a
          reactive ([Provider_overflow]) prepare is refused before the
          checkpoint load and the summarizer LLM call — the settlement's
          per-stimulus escalation already stops the retries, and this gate
          stops the one bounded LLM attempt each new stimulus still paid.
          [Manual] prepares bypass the gate: an operator-committed compaction
          resets the streak and lifts the suspension. *)

type prepared_commit_failure =
  { error : compaction_recovery_error
  ; committed : compaction_recovery option
  }

type prepared_commit_completion =
  | Commit_completion_committed of compaction_recovery
  | Commit_completion_rejected of no_compaction
  | Commit_completion_failed of prepared_commit_failure

type prepared_commit_outcome =
  | Committed of compaction_recovery
  | Commit_in_progress of prepared_commit_completion Eio.Promise.t
  | Already_committed of compaction_recovery
  | Already_rejected of no_compaction
  | Commit_failed of prepared_commit_failure

val compaction_recovery_error_to_tag : compaction_recovery_error -> string
val compaction_recovery_error_to_string : compaction_recovery_error -> string

(** End-of-turn pipeline. Preserves the checkpoint and persists the result to
    the keeper meta and dashboard surface. Explicit compaction is a separate
    request path; Keeper autonomy remains owned by its heartbeat/turn lane. *)
val apply_post_turn_lifecycle_with_resilience_handles :
  resilience_audit_store:Shared_audit.Store.t option ->
  resilience_strategy_executor:Resilience.Recovery.strategy_executor option ->
  meta:Keeper_meta_contract.keeper_meta ->
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

type prepared_compaction
(** Fully-planned compaction: durable source loaded, policy and LLM plan
    computed, nothing committed yet.  Carrying this value lets a caller run
    the provider call outside any keeper admission and commit later — the
    source CAS, not the turn slot, is the interleaving guard. The token is
    opaque and owns the exact Keeper identity and commit policy captured at
    preparation; callers cannot construct it or combine a plan with another
    Keeper's metadata. It also owns the real post-dispatch observation and
    durable terminalizer used by every uncommitted terminal path. *)

type uncommitted_prepared_outcome =
  | Uncommitted_terminalized of no_compaction
  | Uncommitted_commit_in_progress of
      prepared_commit_completion Eio.Promise.t
  | Uncommitted_already_committed of compaction_recovery
  | Uncommitted_failed of compaction_recovery_error

(** Phase 1: load the durable source and run the policy + LLM planner.
    Admission-free by contract; the caller must not hold the keeper's turn
    slot while this runs. *)
val prepare_compaction :
  ?before_dispatch_authority:
    Keeper_compaction_llm_summarizer.before_dispatch_authority ->
  base_path:string ->
  base_dir:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  trigger:Compaction_trigger.t ->
  unit ->
  (prepared_compaction, compaction_recovery_error) result

(** Phase 2: source-CAS commit of a fully-planned compaction.  The caller
    decides which admission (if any) guards this phase. *)
val commit_prepared_compaction :
  prepared_compaction -> prepared_commit_outcome

module For_testing : sig
  val commit_prepared_compaction_with_history :
    ?after_checkpoint_installed:(unit -> unit) ->
    ?complete_post_success_commit:
      (Keeper_compaction_llm_summarizer.post_success_terminalizer ->
       (unit, string) result) ->
    save_oas_history:
      (session_dir:string -> Agent_sdk.Checkpoint.t -> unit) ->
    prepared_compaction ->
    prepared_commit_outcome

  val post_success_snapshot :
    prepared_compaction ->
    Keeper_compaction_llm_summarizer.post_success_snapshot

  val claim_post_success_commit :
    prepared_compaction ->
    Keeper_compaction_llm_summarizer.post_success_commit_claim
end

(** Affine disposition for a prepared exact-output result that cannot enter
    its commit admission. A reject owner durably quarantines; a commit loser
    receives the canonical completion waiter/evidence and must not redispatch
    the provider. *)
val no_compaction_of_uncommitted_prepared :
  ?cause:Keeper_event_queue_state.exact_execution_terminal_cause ->
  prepared_compaction -> uncommitted_prepared_outcome

(** Reload the canonical OAS checkpoint and apply an explicit typed
    compaction request. Composition of {!prepare_compaction} and
    {!commit_prepared_compaction}; all affine ownership outcomes remain
    explicit. *)
val recover_latest_checkpoint_for_compaction :
  ?before_dispatch_authority:
    Keeper_compaction_llm_summarizer.before_dispatch_authority ->
  base_path:string ->
  base_dir:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  trigger:Compaction_trigger.t ->
  unit ->
  prepared_commit_outcome
