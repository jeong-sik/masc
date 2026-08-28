(** MASC-owned compaction planning over the provider-neutral AGENT_CORE exact-output
    surface. Target selection, admission, wire serialization, credentials, and
    dispatch receipts remain AGENT_CORE-owned. *)

type compaction_plan
type planning_window

type exact_execution_evidence

type completed_plan

type prepared_lane

val prepared_ordered_slot_ids : prepared_lane -> string list
(** The frozen candidate order of a prepared flow, after lane resolution and
    the per-keeper exact-lane preference. Observation only; the flow itself
    is immutable. *)

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
    AGENT_CORE dispatches a candidate. AGENT_CORE owns execution, advancement, and exact
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
  | No_reducible_boundary
  | Invalid_plan

type summarizer =
  units:Keeper_compaction_unit.closed_unit list ->
  (completed_plan, summarization_failure) result

(** Pure lane lookup and construction of one immutable AGENT_CORE exact flow against
    exactly one caller-supplied registry generation. MASC supplies only ordered
    opaque slot identities and domain messages/schema. AGENT_CORE freezes candidate
    visits and allocates one non-shared affine attempt only when that candidate
    is reached, before any network effect. *)
val prepare_lane
  :  base_path:string
  -> keeper_name:string
  -> registry:Runtime_exact_output_registry.t
  -> lane_id:string
  -> units:Keeper_compaction_unit.closed_unit list
  -> (prepared_lane, summarization_failure) result

(** Execute the immutable AGENT_CORE flow exactly once. AGENT_CORE exclusively decides
    whether an execution failure can advance and supplies the predetermined
    successor. MASC validates only the caller-owned source immediately before
    dispatch and never reconstructs execution state from a second durable
    claim. Cancellation is always re-raised rather than projected as a
    compaction outcome; an authorized source observation is retained only for
    the cancellation log.
    Domain-invalid output is rejected by the validator and AGENT_CORE advances to the
    next caller-declared candidate. The same validator applies the proposed
    rolling summary, selects the next oldest raw source, and projects that next
    request through every frozen slot's AGENT_CORE serializer. A summary that would
    make the next fold exceed any declared request-body cap is domain-invalid
    before checkpoint installation. Exhaustion is source-terminal. *)
val execute_prepared_lane
  :  keeper_name:string
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:_ Eio.Time.clock
  -> ?before_dispatch_authority:before_dispatch_authority
  -> ?observation_registry:Exact_lane_run_registry.t
  -> prepared_lane
  -> (completed_plan, summarization_failure) result

(** Resolve [compaction_exact] from one published immutable registry and hand
    its ordered opaque slots to one AGENT_CORE exact flow. AGENT_CORE owns admission,
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

val exact_execution_evidence_slot_id : exact_execution_evidence -> string
val exact_execution_evidence_call_id : exact_execution_evidence -> string
val exact_execution_evidence_target_identity_fingerprint : exact_execution_evidence -> string
val exact_execution_evidence_catalog_generation_fingerprint : exact_execution_evidence -> string
val exact_execution_evidence_catalog_evidence_sha256 : exact_execution_evidence -> string
val exact_execution_evidence_plan_fingerprint : exact_execution_evidence -> string
val exact_execution_evidence_receipt_request_body_sha256 : exact_execution_evidence -> string
val exact_execution_terminal
  :  cause:Keeper_compaction_outcome.exact_execution_terminal_cause
  -> exact_execution_evidence
  -> Keeper_compaction_outcome.exact_execution_terminal
(** Pure typed projection of the AGENT_CORE receipt identity retained by a successful
    exact execution. It owns no claim, lock, waiter, or lifecycle state. *)

val apply : compaction_plan -> Agent_core.Types.message list
val summarized_indices : compaction_plan -> int list
val dropped_indices : compaction_plan -> int list
val has_changes : compaction_plan -> bool

module For_testing : sig
  val messages_for_plan
    :  window:planning_window -> Agent_core.Types.message list

  val planning_window_for_units
    :  Keeper_compaction_unit.closed_unit list
    -> (planning_window, string) result

  val planning_window_source_indices : planning_window -> int list

  val prepared_window_source_indices : prepared_lane -> int list
  val flow_slot_ids : prepared_lane -> string list

  val attempt_observations : prepared_lane -> attempt_observation list
  val candidate_snapshot_slot_ids : prepared_lane -> string list
end
