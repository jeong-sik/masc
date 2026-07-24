(** MASC-owned compaction planning over the provider-neutral OAS exact-output
    surface. Target selection, admission, wire serialization, credentials, and
    dispatch receipts remain OAS-owned. *)

type compaction_plan

type exact_execution_evidence

type completed_plan

type post_success_terminalizer

type prepared_lane

type attempt_observation =
  { slot_id : string
  ; call_id : string
  ; catalog_generation_fingerprint : string
  ; receipt_plan_fingerprint : string
  ; receipt_request_body_sha256 : string
  }

type exact_write_outcome = Keeper_event_queue_persistence.exact_write_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string

type exact_execution_guard =
  { before_dispatch : attempt_observation -> (exact_write_outcome, string) result
  ; release_before_dispatch : attempt_observation -> (exact_write_outcome, string) result
  ; quarantine :
      Keeper_event_queue_state.exact_execution_terminal_cause ->
      attempt_observation ->
      (exact_write_outcome, string) result
  }
(** Explicit lease-scoped exact-execution persistence authority.
    [before_dispatch] must return [Fsync_completed] before POST; this means
    payload and parent [Unix.fsync] returned and supports process-restart
    safety, not hardware/power-loss persistence or Darwin [F_FULLFSYNC].
    Visible uncertainty returns a source-bound terminal without POST.
    [release_before_dispatch] is invoked only for the failed identity selected
    by OAS and permits OAS to advance only after [Fsync_completed]. Visible or
    failed removal returns a terminal for that identity and cannot dispatch its
    successor. A visible [quarantine] preserves the original terminal cause for
    source-bound settlement. None of these callbacks selects a successor or
    performs POST. *)

type summarization_failure =
  | Exact_lane_unconfigured
  | Exact_target_selection_failed
  | Exact_admission_failed
  | Exact_attempt_start_failed
  | Exact_execution_context_unavailable
  | Exact_execution_guard_failed
  | Exact_flow_already_started
  | Exact_execution_terminal of Keeper_event_queue_state.exact_execution_terminal
  | Invalid_plan

type summarizer =
  units:Keeper_compaction_unit.closed_unit list ->
  (completed_plan, summarization_failure) result

(** Pure lane lookup and construction of one immutable OAS exact flow against
    exactly one caller-supplied registry generation. MASC supplies only ordered
    opaque slot identities and domain messages/schema. OAS performs candidate
    admission and allocates every non-shared affine attempt before any network
    effect. *)
val prepare_lane
  :  keeper_name:string
  -> registry:Runtime_exact_output_registry.t
  -> lane_id:string
  -> units:Keeper_compaction_unit.closed_unit list
  -> (prepared_lane, summarization_failure) result

(** Execute the immutable OAS flow exactly once. OAS exclusively decides
    whether an execution failure can advance and supplies the predetermined
    successor. MASC only durably binds the supplied identity, durably releases
    the failed identity, and quarantines source-bound terminal identities.
    MASC never reads receipt phase/count or provider/admission failure causes.
    Cancellation before a durable bind is re-raised. Once a durable bind exists,
    cancellation is a phase-neutral source-bound terminal unless OAS first
    invokes [release_before_dispatch]; MASC never reconstructs dispatch state
    from cancellation or receipt details.
    Domain-invalid output is terminal and cannot enter OAS failover. *)
val execute_prepared_lane
  :  keeper_name:string
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:_ Eio.Time.clock
  -> ?exact_execution_guard:exact_execution_guard
  -> prepared_lane
  -> (completed_plan, summarization_failure) result

(** Resolve [compaction_exact] from one published immutable registry and hand
    its ordered opaque slots to one OAS exact flow. OAS owns admission,
    execute-once, advancement, and provenance. [plan_of_json] alone enforces the
    MASC-owned compaction schema and domain rules after success. *)
val make : ?exact_execution_guard:exact_execution_guard -> keeper_name:string -> unit -> summarizer option

val has_eligible_units : Keeper_compaction_unit.closed_unit list -> bool

val plan_of_json
  :  units:Keeper_compaction_unit.closed_unit list
  -> Yojson.Safe.t
  -> (compaction_plan, string) result

val completed_plan : completed_plan -> compaction_plan
val completed_exact_execution_evidence : completed_plan -> exact_execution_evidence
val completed_attempt_observation : completed_plan -> attempt_observation
val completed_post_success_terminalizer : completed_plan -> post_success_terminalizer

val terminalize_post_success
  :  post_success_terminalizer
  -> Keeper_event_queue_state.exact_execution_terminal_cause
  -> Keeper_event_queue_state.exact_execution_terminal
(** Durably quarantine the real retained attempt observation before returning
    its source-bound terminal identity. The first call atomically owns the
    canonical cause, performs the only quarantine attempt outside the mutex
    under cancellation protection, and releases concurrent waiters. Later calls
    return that same terminal even when they propose a different cause.
    Persistence errors and raised exceptions are logged without replacing the
    canonical terminal; the durable binding remains dispatch-uncertain and
    therefore fail-closed against restart replay. A cancelled waiter can retry
    and retrieve the same canonical terminal without repeating quarantine. *)

val exact_execution_evidence_slot_id : exact_execution_evidence -> string
val exact_execution_evidence_call_id : exact_execution_evidence -> string
val exact_execution_evidence_target_identity_fingerprint : exact_execution_evidence -> string
val exact_execution_evidence_catalog_generation_fingerprint : exact_execution_evidence -> string
val exact_execution_evidence_catalog_evidence_sha256 : exact_execution_evidence -> string
val exact_execution_evidence_plan_fingerprint : exact_execution_evidence -> string
val exact_execution_evidence_receipt_plan_fingerprint : exact_execution_evidence -> string
val exact_execution_evidence_receipt_request_body_sha256 : exact_execution_evidence -> string
val apply : compaction_plan -> Agent_sdk.Types.message list
val summarized_indices : compaction_plan -> int list
val dropped_indices : compaction_plan -> int list
val has_changes : compaction_plan -> bool

module For_testing : sig
  val messages_for_plan
    :  units:Keeper_compaction_unit.closed_unit list
    -> Agent_sdk.Types.message list

  val flow_slot_ids : prepared_lane -> string list
  val registry_generation : prepared_lane -> int64

  val attempt_observations : prepared_lane -> attempt_observation list
end
