(** MASC-owned compaction planning over the provider-neutral OAS exact-output
    surface. Target selection, admission, wire serialization, credentials, and
    dispatch receipts remain OAS-owned. *)

type compaction_plan
type planning_window

type exact_execution_evidence

type completed_plan

type post_success_terminalizer

type post_success_terminalization =
  | Terminalized of Keeper_compaction_outcome.exact_execution_terminal
  | Terminalization_commit_in_progress of unit Eio.Promise.t
  | Terminalization_already_committed
  | Terminalization_invariant_failed of string

type post_success_commit_claim =
  | Commit_claim_acquired
  | Commit_claim_in_progress of unit Eio.Promise.t
  | Commit_claim_already_committed
  | Commit_claim_rejected of Keeper_compaction_outcome.exact_execution_terminal

type 'a post_success_commit_boundary =
  | Post_success_commit_result of 'a
  | Post_success_commit_in_progress of unit Eio.Promise.t
  | Post_success_commit_already_committed
  | Post_success_commit_rejected of
      Keeper_compaction_outcome.exact_execution_terminal

type post_success_phase_snapshot =
  | Phase_open
  | Phase_commit_claimed
  | Phase_installed_pending_valid
  | Phase_committed
  | Phase_reject_claimed
  | Phase_rejected

type post_success_snapshot =
  { phase : post_success_phase_snapshot
  ; domain_valid_attempts : int
  ; domain_rejected_attempts : int
  }

type prepared_lane

type attempt_observation =
  { slot_id : string
  ; call_id : string
  ; catalog_generation_fingerprint : string
  ; receipt_plan_fingerprint : string
  ; receipt_request_body_sha256 : string
  }

type before_dispatch_authority =
  attempt_observation -> (unit, string) result
(** Validate the caller-owned source and Keeper lifecycle immediately before
    OAS dispatches a candidate. OAS owns execution, advancement, and exact
    attempt provenance; this callback neither persists a parallel execution
    claim nor interprets provider progress. *)

type summarization_failure =
  | Exact_lane_unconfigured
  | Exact_target_selection_failed
  | Exact_admission_failed
  | Exact_attempt_start_failed
  | Exact_execution_context_unavailable
  | Exact_execution_authority_absent
  | Exact_execution_authority_rejected
  | Exact_flow_already_started
  | Exact_execution_terminal of Keeper_compaction_outcome.exact_execution_terminal
  | Invalid_plan

type summarizer =
  units:Keeper_compaction_unit.closed_unit list ->
  (completed_plan, summarization_failure) result

(** Pure lane lookup and construction of one immutable OAS exact flow against
    exactly one caller-supplied registry generation. MASC supplies only ordered
    opaque slot identities and domain messages/schema. OAS freezes candidate
    visits and allocates one non-shared affine attempt only when that candidate
    is reached, before any network effect. *)
val prepare_lane
  :  base_path:string
  -> keeper_name:string
  -> registry:Runtime_exact_output_registry.t
  -> lane_id:string
  -> units:Keeper_compaction_unit.closed_unit list
  -> (prepared_lane, summarization_failure) result

(** Execute the immutable OAS flow exactly once. OAS exclusively decides
    whether an execution failure can advance and supplies the predetermined
    successor. MASC validates only the caller-owned source immediately before
    dispatch and never reconstructs execution state from a second durable
    claim. Cancellation before authorization is re-raised; cancellation after
    authorization is projected as a source-bound terminal for that exact
    candidate.
    Domain-invalid output is rejected by the validator and OAS advances to the
    next caller-declared candidate. The same validator applies the proposed
    rolling summary, selects the next oldest raw source, and projects that next
    request through every frozen slot's OAS serializer. A summary that would
    make the next fold exceed any declared request-body cap is domain-invalid
    before checkpoint installation. Exhaustion is source-terminal. *)
val execute_prepared_lane
  :  keeper_name:string
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:_ Eio.Time.clock
  -> ?before_dispatch_authority:before_dispatch_authority
  -> prepared_lane
  -> (completed_plan, summarization_failure) result

(** Resolve [compaction_exact] from one published immutable registry and hand
    its ordered opaque slots to one OAS exact flow. OAS owns admission,
    execute-once, advancement, and provenance. [plan_of_json] alone enforces the
    MASC-owned compaction schema and domain rules after success. *)
val make
  :  ?before_dispatch_authority:before_dispatch_authority
  -> base_path:string
  -> keeper_name:string
  -> unit
  -> summarizer option

val has_eligible_units : Keeper_compaction_unit.closed_unit list -> bool

val plan_of_json
  :  window:planning_window
  -> Yojson.Safe.t
  -> (compaction_plan, string) result

val completed_plan : completed_plan -> compaction_plan
val completed_exact_execution_evidence : completed_plan -> exact_execution_evidence
val completed_attempt_observation : completed_plan -> attempt_observation
val completed_post_success_terminalizer : completed_plan -> post_success_terminalizer

val claim_post_success_commit :
  post_success_terminalizer -> post_success_commit_claim

(** Only the [Open] claimant executes [commit]. *)
val with_post_success_commit :
  post_success_terminalizer ->
  (unit -> 'a) ->
  'a post_success_commit_boundary

val mark_post_success_checkpoint_installed :
  post_success_terminalizer -> (unit, string) result

val terminalize_claimed_commit :
  post_success_terminalizer ->
  Keeper_compaction_outcome.exact_execution_terminal_cause ->
  post_success_terminalization

val terminalize_post_success
  :  post_success_terminalizer
  -> Keeper_compaction_outcome.exact_execution_terminal_cause
  -> post_success_terminalization
(** Close the process-local post-success phase with the retained OAS attempt
    identity. The first call atomically owns the canonical cause and releases
    concurrent waiters; later calls return the same terminal even when they
    propose a different cause. This does not create or persist a second
    execution claim. *)

val complete_post_success_commit
  :  post_success_terminalizer
  -> (unit, string) result
(** Complete the existing affine post-success phase after the validated
    compaction checkpoint is durable. *)

val finish_post_success_commit_failure
  :  post_success_terminalizer
  -> string
  -> (unit, string) result
(** After durable checkpoint installation, conservatively finalize
    the affine commit and always release its existing completion waiter. *)

val exact_execution_evidence_slot_id : exact_execution_evidence -> string
val exact_execution_evidence_call_id : exact_execution_evidence -> string
val exact_execution_evidence_target_identity_fingerprint : exact_execution_evidence -> string
val exact_execution_evidence_catalog_generation_fingerprint : exact_execution_evidence -> string
val exact_execution_evidence_catalog_evidence_sha256 : exact_execution_evidence -> string
val exact_execution_evidence_plan_fingerprint : exact_execution_evidence -> string
val exact_execution_evidence_receipt_request_body_sha256 : exact_execution_evidence -> string
val apply : compaction_plan -> Agent_sdk.Types.message list
val summarized_indices : compaction_plan -> int list
val dropped_indices : compaction_plan -> int list
val has_changes : compaction_plan -> bool

module For_testing : sig
  val messages_for_plan
    :  window:planning_window -> Agent_sdk.Types.message list

  val planning_window_for_units
    :  Keeper_compaction_unit.closed_unit list
    -> (planning_window, string) result

  val planning_window_source_indices : planning_window -> int list

  val prepared_window_source_indices : prepared_lane -> int list
  val flow_slot_ids : prepared_lane -> string list
  val registry_generation : prepared_lane -> int64

  val attempt_observations : prepared_lane -> attempt_observation list
  val candidate_snapshot_slot_ids : prepared_lane -> string list

  val post_success_snapshot :
    post_success_terminalizer -> post_success_snapshot

end
