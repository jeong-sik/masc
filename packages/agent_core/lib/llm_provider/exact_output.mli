type measurement_dispatch_fact =
  | No_measurement_dispatch
  | Measurement_dispatch_unknown
  | Measurement_dispatch_started

type measurement_outcome =
  | Measurement_not_required
  | Measurement_succeeded
  | Measurement_unsupported
  | Measurement_local_invalid
  | Measurement_transport_failed
  | Measurement_invalid_response
  | Measurement_fence_rejected
  | Measurement_cancelled

type measurement_evidence =
  { dispatch : measurement_dispatch_fact
  ; outcome : measurement_outcome
  }

type measurement_operation_id

type measurement_receipt_phase =
  | Measurement_fence_committed
  | Measurement_wire_started
  | Measurement_terminal

(** Provider-neutral, exact structured-output Single Surface.

    The canonical downstream path is [Agent_sdk.Exact_output]. The
    [Llm_provider.Exact_output] path is the same packaged module, not a second
    contract or entrypoint.

    The caller supplies an immutable OAS resolver snapshot, one exact target
    reference, messages, a raw domain JSON schema, and the minimum guarantee. Provider
    config, wire response formats, schema envelopes, capability overrides,
    tools, reasoning controls, token measurement, and retry/fallback are
    deliberately absent from this interface. *)

type resolver_snapshot
type admitted_target
type catalog_generation
type catalog_evidence
type target_identity
type selected_target
type output_requirement
type ready_plan
type attempt
type receipt
type call_id
type schema_fingerprint
type flow_candidate
type flow_snapshot
type flow_attempt
type flow_success
type resolver_io = { getenv : string -> (string option, unit) result }

type catalog_document =
  { source : string
  ; contents : string
  }

type resolver_catalog_input =
  | Embedded_default
  | Embedded_with_overlay of catalog_document
  | Full_replacement of catalog_document
  | Full_replacement_file of string

type target_ref_error =
  | Empty_target_ref
  | Invalid_target_ref

type resolver_catalog_source =
  | Embedded_catalog
  | Full_replacement_catalog
  | Overlay_catalog

type resolver_collision =
  | Duplicate_provider_identity
  | Duplicate_model_identity
  | Duplicate_target_identity
  | Provider_alias_shadow
  | Target_identity_shadow
  | Model_identity_shadow

type resolver_binding_component =
  | Target_provider
  | Target_model

type resolver_endpoint_error =
  | Malformed_base_url
  | Base_url_userinfo_not_allowed
  | Base_url_query_not_allowed
  | Base_url_fragment_not_allowed
  | Invalid_request_path
  | Unsupported_gemini_request_path
  | Invalid_gemini_model_path

type resolver_snapshot_error =
  | Catalog_read_failed of
      { path : string
      ; detail : string
      }
  | Catalog_parse_failed of
      { source : resolver_catalog_source
      ; detail : string
      }
  | Target_catalog_invalid of
      { source : resolver_catalog_source
      ; detail : string
      }
  | Catalog_collision of resolver_collision
  | Target_binding_missing of
      { target_ref : string
      ; component : resolver_binding_component
      }
  | Target_endpoint_invalid of
      { target_ref : string
      ; cause : resolver_endpoint_error
      }
  | Environment_read_failed of { environment_variable : string }

type minimum_guarantee =
  | Json_syntax
  (** Prompt-only JSON contract.  OAS appends the schema instruction and
          validates the response locally; it does not send a provider-native
          response-format request. *)
  | Provider_schema (** Explicit opt-in to a provider-native schema request. *)

type actual_assurance =
  | Json_syntax_only
  | Provider_schema_requested

type target_selection_error

type target_catalog_admission_error =
  | Target_ref_rejected of target_ref_error
  | Target_not_in_catalog of string

type wire_admission_error
type admission_error

type request_body_projection = private
  { actual_bytes : int
  ; limit_bytes : int option
  ; within_limit : bool
  }

type token_capacity_rejection =
  | Capacity_evidence_not_yet_valid of
      { now_unix_s : int
      ; checked_at_unix_s : int
      }
  | Capacity_evidence_expired of
      { now_unix_s : int
      ; expires_at_unix_s : int
      }
  | Capacity_boundary_unknown of
      { input_tokens : int
      ; accepted_through_tokens : int
      ; rejected_from_tokens : int option
      }
  | Capacity_input_rejected of
      { input_tokens : int
      ; accepted_through_tokens : int
      ; rejected_from_tokens : int
      }

type input_capacity_disposition =
  | Token_measurement_required of
      { accepted_through_tokens : int
      ; rejected_from_tokens : int option
      }
  | Context_window_exceeded of
      { input_tokens : int
      ; reserved_output_tokens : int
      ; max_context_tokens : int
      }
  | Token_capacity_rejected of token_capacity_rejection
  | Serialized_request_body_too_large of
      { actual_bytes : int
      ; limit_bytes : int
      }

type candidate_rejection_disposition =
  | Runtime_slot_unavailable
  | Runtime_contract_rejected
  | Input_contract_rejected
  | Output_requirement_rejected
  | Input_capacity of input_capacity_disposition
  | Request_preparation_failed

type plan_provenance

type effect_phase =
  | Not_started
  | Before_dispatch
  | Dispatch_started
  | Response_received
  | Terminal

(** Provider-neutral response evidence owned by OAS. Detailed headers and
    provider metadata remain opaque; consumers compare only its fingerprint. *)
type provider_trace

type raw_response =
  { body : string
  ; body_sha256 : string
  }

type execution_error_cause =
  | Attempt_already_started
  | Clock_required_for_timeout
  | Frozen_request_mismatch
  | Completion_failed
  | Serialized_request_refused of { http_status : int }
  | Incomplete_output
  | Missing_output
  | Ambiguous_output of int
  | Unexpected_output_content
  | Invalid_json_output
  | Internal_non_json_output

type execution_error =
  { call_id : call_id
  ; receipt : receipt
  ; cause : execution_error_cause
  ; raw_response : raw_response option
  }

type success =
  { call_id : call_id
  ; receipt : receipt
  ; output : Yojson.Safe.t
  ; provenance : plan_provenance
  ; raw_response : raw_response
  }

(** Provider-neutral identity for one caller-labelled candidate in a frozen
    exact flow. The target fields remain opaque and can only be projected to
    their stable fingerprints. *)
type flow_candidate_identity =
  { candidate_id : string
  ; catalog_generation : catalog_generation
  ; catalog_evidence : catalog_evidence
  ; target_identity : target_identity
  }

type flow_id
type flow_visit_ordinal
type candidate_visit_count

type flow_candidate_visit = private
  { flow_id : flow_id
  ; ordinal : flow_visit_ordinal
  ; identity : flow_candidate_identity
  }

type flow_measurement_receipt

type measurement_receipt_snapshot = private
  { operation_id : measurement_operation_id
  ; flow_id : flow_id
  ; visit_ordinal : flow_visit_ordinal
  ; candidate_id : string
  ; candidate_binding_sha256 : string
  ; catalog_generation_fingerprint : string
  ; catalog_evidence_sha256 : string
  ; request_body_sha256 : string
  ; phase : measurement_receipt_phase
  ; dispatch : measurement_dispatch_fact
  ; outcome : measurement_outcome option
  }

type measurement_receipt_snapshot_decode_error =
  | Measurement_receipt_snapshot_malformed_json of string
  | Measurement_receipt_snapshot_invalid_fields
  | Measurement_receipt_snapshot_unknown_format of string
  | Measurement_receipt_snapshot_unsupported_version of int
  | Measurement_receipt_snapshot_invalid_field of string
  | Measurement_receipt_snapshot_integrity_mismatch

type measurement_receipt_transition_conflict =
  | Measurement_operation_mismatch
  | Measurement_operation_binding_mismatch
  | Measurement_invalid_commit_phase of measurement_receipt_phase
  | Measurement_invalid_previous_boundary of
      { phase : measurement_receipt_phase
      ; dispatch : measurement_dispatch_fact
      ; outcome : measurement_outcome option
      }
  | Measurement_phase_regression of
      { previous_phase : measurement_receipt_phase
      ; incoming_phase : measurement_receipt_phase
      }
  | Measurement_evidence_conflict

type measurement_receipt_transition =
  | Measurement_dispatch_intent
  | Measurement_terminal_advance
  | Measurement_idempotent_replay
  | Measurement_transition_conflict of measurement_receipt_transition_conflict

type candidate_rejection_receipt

type admitted_flow_candidate =
  { visit : flow_candidate_visit
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; provenance : plan_provenance
  ; measurement : measurement_evidence
  }

type candidate_admission =
  | Candidate_admitted of admitted_flow_candidate
  | Candidate_rejected of candidate_rejection_receipt

type flow_candidate_error = Blank_flow_candidate_id

type flow_snapshot_error =
  | Duplicate_flow_candidate_id of
      { candidate_id : string
      ; first_position : int
      ; duplicate_position : int
      }

(** Construct one provider-neutral candidate from a catalog-admitted target.
    Credential selection remains frozen but unresolved until this candidate is
    reached by the declared-order flow. The trimmed caller identity must be
    nonempty and is otherwise opaque to OAS. *)
val make_flow_candidate
  :  id:string
  -> admitted_target:admitted_target
  -> (flow_candidate, flow_candidate_error) result

val flow_candidate_identity : flow_candidate -> flow_candidate_identity

(** Freeze one nonempty caller-declared candidate order and its immutable
    domain input. This validates only flow topology. Credential selection and
    exact request admission are deferred until each candidate is reached.
    No preference store, provider ranking, or future observation may reorder the
    snapshot. *)
val snapshot_flow
  :  first:flow_candidate
  -> rest:flow_candidate list
  -> messages:Types.message list
  -> output_requirement
  -> (flow_snapshot, flow_snapshot_error) result

(** Parse exactly one typed catalog input and freeze a private immutable target
    map. The default input is the embedded OAS catalog. [Embedded_with_overlay]
    applies the existing sparse exact-output overlay precedence to that
    embedded base. A full replacement, supplied as owned bytes or a file path,
    suppresses every embedded and overlay row; the input type provides no way
    to combine a full replacement with an overlay.
    [io.getenv] is observed exactly once per referenced environment name during
    this call and is never retained. Invalid paths, syntax, bindings,
    collisions, base-URL environment reads, and endpoint declarations fail
    closed; missing, invalid, or read-failed credentials are instead frozen as
    per-target outcomes for [resolve_target]. No source falls back to the
    embedded catalog. *)
val load_resolver_snapshot
  :  io:resolver_io
  -> ?catalog:resolver_catalog_input
  -> unit
  -> (resolver_snapshot, resolver_snapshot_error) result

val resolver_catalog_generation : resolver_snapshot -> catalog_generation
val resolver_catalog_evidence : resolver_snapshot -> catalog_evidence
val catalog_generation_fingerprint : catalog_generation -> string
val catalog_evidence_sha256 : catalog_evidence -> string
val target_identity_fingerprint : target_identity -> string
val selected_target_identity : selected_target -> target_identity
val selected_target_catalog_generation : selected_target -> catalog_generation
val selected_target_catalog_evidence : selected_target -> catalog_evidence

(** Validate [value], prove that its exact identity exists in [resolver_snapshot],
    and capture that frozen target together with its catalog generation and
    evidence. Credential outcomes are intentionally deferred to [resolve_target]. *)
val admit_target_ref
  :  resolver_snapshot
  -> string
  -> (admitted_target, target_catalog_admission_error) result

(** Resolve the binding captured by [admit_target_ref]. This performs no map,
    environment, global, alias, default-model, ranking, probing, or fallback
    lookup. It injects an available frozen secret into a fresh provider config,
    or reports the frozen missing, invalid, or read-failed credential outcome. *)
val resolve_target : admitted_target -> (selected_target, target_selection_error) result

(** Brand an opaque domain JSON schema. OAS never interprets domain keys as a
    provider wire envelope; it always constructs the selected target's wire
    envelope itself. *)
val make_output_requirement
  :  schema:Yojson.Safe.t
  -> minimum_guarantee:minimum_guarantee
  -> output_requirement

(** Project the exact serialized generation-body size for one catalog-admitted
    target without resolving credentials, allocating an attempt, measuring
    tokens, or dispatching. The same provider serializer and output requirement
    transformation used by admission produce [actual_bytes].

    [within_limit] compares only the target's declared request-body ceiling.
    This function is not a token/context-fit oracle; callers must not convert
    bytes to tokens or infer an undeclared context boundary from it. *)
val project_request_body
  :  target:admitted_target
  -> messages:Types.message list
  -> output_requirement
  -> (request_body_projection, admission_error) result

(** Pure admission. It performs no token-count request, estimation, provider
    completion, or global admission. The returned immutable plan freezes one
    selected target and one serialized request. *)
val admit
  :  target:selected_target
  -> messages:Types.message list
  -> output_requirement
  -> (ready_plan, admission_error) result

val plan_provenance : ready_plan -> plan_provenance
val plan_provenance_source_schema_fingerprint : plan_provenance -> schema_fingerprint

val plan_provenance_effective_schema_fingerprint
  :  plan_provenance
  -> schema_fingerprint option

val plan_provenance_actual_assurance : plan_provenance -> actual_assurance
val plan_provenance_catalog_generation : plan_provenance -> catalog_generation
val plan_provenance_catalog_evidence : plan_provenance -> catalog_evidence
val plan_provenance_target_identity : plan_provenance -> target_identity
val plan_fingerprint : ready_plan -> string
val schema_fingerprint_to_string : schema_fingerprint -> string

type start_attempt_error = Call_id_generation_failed of string

type measurement_start_error =
  | Measurement_operation_id_generation_failed of string
  | Measurement_clock_required_for_timeout

type flow_start_error = Flow_id_generation_failed of string

(** Allocate a fresh, independent execution attempt for an admitted plan.
    [admit] remains pure and the same immutable plan may start multiple attempts.
    Each attempt owns an opaque call identity and affine execution state. *)
val start_attempt : ready_plan -> (attempt, start_attempt_error) result

(** Allocate one fresh outer-flow identity and precompute one immutable visit
    for each frozen candidate. This performs no credential selection, request
    admission, call identity allocation, callback, or network effect. A new
    invocation always creates a new flow; restart resume belongs to the
    caller's authenticated durable journal. *)
val start_flow : flow_snapshot -> (flow_attempt, flow_start_error) result

val call_id_to_string : call_id -> string
val flow_id_to_string : flow_id -> string
val flow_visit_ordinal_to_int : flow_visit_ordinal -> int
val flow_attempt_id : flow_attempt -> flow_id
val attempt_receipt : attempt -> receipt
val receipt_call_id : receipt -> call_id
val receipt_phase : receipt -> effect_phase
val receipt_dispatch_count : receipt -> int
val receipt_http_status : receipt -> int option
val receipt_provider_trace : receipt -> provider_trace option
val provider_trace_fingerprint : provider_trace -> string
val receipt_plan_fingerprint : receipt -> string
val receipt_request_body_sha256 : receipt -> string
val receipt_catalog_generation : receipt -> catalog_generation
val receipt_catalog_evidence : receipt -> catalog_evidence
val receipt_target_identity : receipt -> target_identity

(** Immutable generation-receipt fact captured from one atomic state read. *)
type generation_receipt_snapshot

val generation_receipt_snapshot : receipt -> generation_receipt_snapshot
val generation_receipt_snapshot_phase : generation_receipt_snapshot -> effect_phase
val generation_receipt_snapshot_dispatch_count : generation_receipt_snapshot -> int
val generation_receipt_snapshot_http_status : generation_receipt_snapshot -> int option

val generation_receipt_snapshot_provider_trace
  :  generation_receipt_snapshot
  -> provider_trace option

val generation_receipt_snapshot_call_id : generation_receipt_snapshot -> call_id
val generation_receipt_snapshot_plan_fingerprint : generation_receipt_snapshot -> string

val generation_receipt_snapshot_request_body_sha256
  :  generation_receipt_snapshot
  -> string

val generation_receipt_snapshot_catalog_generation
  :  generation_receipt_snapshot
  -> catalog_generation

val generation_receipt_snapshot_catalog_evidence
  :  generation_receipt_snapshot
  -> catalog_evidence

val generation_receipt_snapshot_target_identity
  :  generation_receipt_snapshot
  -> target_identity

(** One immutable outer-flow binding. The opaque candidate identity and one-shot
    execution receipt travel together; consumers do not rebuild that join from
    coordinator or target strings. *)
type flow_attempt_receipt = private
  { visit : flow_candidate_visit
  ; receipt : receipt
  }

(** Immutable evidence copy of one generation attempt. *)
type flow_attempt_snapshot = private
  { visit : flow_candidate_visit
  ; receipt : generation_receipt_snapshot
  }

type flow_advance_failure_snapshot =
  | Flow_advance_candidate_rejected of candidate_rejection_receipt
  | Flow_advance_execution_failed of
      { candidate : flow_attempt_snapshot
      ; cause : execution_error_cause
      ; raw_response_sha256 : string option
      }

type flow_advance_receipt = private
  { failed : flow_advance_failure_snapshot
  ; next : flow_candidate_visit
  }

val candidate_visit_count_to_int : candidate_visit_count -> int
val measurement_operation_id_to_string : measurement_operation_id -> string

val flow_measurement_receipt_snapshot
  :  flow_measurement_receipt
  -> measurement_receipt_snapshot

val measurement_receipt_operation_id
  :  measurement_receipt_snapshot
  -> measurement_operation_id

val measurement_receipt_flow_id : measurement_receipt_snapshot -> flow_id
val measurement_receipt_visit_ordinal : measurement_receipt_snapshot -> flow_visit_ordinal
val measurement_receipt_candidate_id : measurement_receipt_snapshot -> string
val measurement_receipt_candidate_binding_sha256 : measurement_receipt_snapshot -> string

val measurement_receipt_catalog_generation_fingerprint
  :  measurement_receipt_snapshot
  -> string

val measurement_receipt_catalog_evidence_sha256 : measurement_receipt_snapshot -> string
val measurement_receipt_request_body_sha256 : measurement_receipt_snapshot -> string
val measurement_receipt_phase : measurement_receipt_snapshot -> measurement_receipt_phase

val measurement_receipt_dispatch_fact
  :  measurement_receipt_snapshot
  -> measurement_dispatch_fact

val measurement_receipt_outcome
  :  measurement_receipt_snapshot
  -> measurement_outcome option

(** Encode one immutable receipt using the sole current durable schema. The
    integrity digest detects corruption; it is not an authenticity signature. *)
val measurement_receipt_snapshot_to_string : measurement_receipt_snapshot -> string

(** Decode only the current complete schema. Missing, extra, legacy, and
    internally inconsistent evidence fails closed. *)
val measurement_receipt_snapshot_of_string
  :  string
  -> (measurement_receipt_snapshot, measurement_receipt_snapshot_decode_error) result

val measurement_receipt_snapshot_decode_error_to_string
  :  measurement_receipt_snapshot_decode_error
  -> string

(** Classify durable callback evidence for one operation. A first snapshot must
    be the committed dispatch intent; only a later terminal snapshot advances
    it. Equal evidence is an idempotent replay. Intermediate live observations
    are not durable callback boundaries and therefore conflict. *)
val classify_measurement_receipt_transition
  :  previous:measurement_receipt_snapshot option
  -> incoming:measurement_receipt_snapshot
  -> measurement_receipt_transition

val target_selection_error_disposition
  :  target_selection_error
  -> candidate_rejection_disposition

val admission_error_disposition : admission_error -> candidate_rejection_disposition
val candidate_rejection_identity : candidate_rejection_receipt -> flow_candidate_identity
val candidate_rejection_visit : candidate_rejection_receipt -> flow_candidate_visit

val candidate_rejection_measurement_dispatch_fact
  :  candidate_rejection_receipt
  -> measurement_dispatch_fact

val candidate_rejection_measurement_outcome
  :  candidate_rejection_receipt
  -> measurement_outcome

val candidate_rejection_disposition
  :  candidate_rejection_receipt
  -> candidate_rejection_disposition

type flow_evidence = private
  { flow_id : flow_id
  ; declared_candidate_snapshot : flow_candidate_identity list
  ; candidate_visit_count : candidate_visit_count
  ; measurements : measurement_receipt_snapshot list
  ; admissions : candidate_admission list
  ; attempts : flow_attempt_snapshot list
  ; advances : flow_advance_receipt list
  }

val flow_success_candidate : flow_success -> flow_attempt_receipt
val flow_success_output : flow_success -> success
val flow_success_evidence : flow_success -> flow_evidence

type ('accepted, 'rejection) semantic_verdict =
  | Accept of 'accepted
  | Reject_and_advance of 'rejection

type 'rejection semantic_rejection_receipt = private
  { transport_success : flow_success
  ; rejection : 'rejection
  }

type 'rejection semantic_rejection_trace = private
  { first : 'rejection semantic_rejection_receipt
  ; rest : 'rejection semantic_rejection_receipt list
  }

type ('accepted, 'rejection) validated_flow_success = private
  { accepted : 'accepted
  ; transport_success : flow_success
  ; prior_rejections : 'rejection semantic_rejection_receipt list
  }

(** Immutable, current-only evidence for one successfully validated flow.
    Decoding reconstructs only this durable snapshot, never a live flow or its
    domain values. *)
type validated_flow_evidence_snapshot

type validated_flow_evidence_source_error
type validated_flow_evidence_invariant_error
type validated_flow_evidence_decode_error

type ('accepted_error, 'rejection_error) validated_flow_evidence_projection_error =
  | Accepted_evidence_projection_failed of 'accepted_error
  | Rejection_evidence_projection_failed of
      { ordinal : int
      ; cause : 'rejection_error
      }
  | Validated_flow_source_evidence_invalid of validated_flow_evidence_source_error
  | Validated_flow_evidence_invariant_failed of validated_flow_evidence_invariant_error

(** Project domain values exactly once in declared visit order and freeze the
    complete successful transcript. Transport/output digests are taken from
    the same typed [flow_success] that produced each semantic verdict. *)
val snapshot_validated_flow_evidence
  :  project_accepted:('accepted -> (Yojson.Safe.t, 'accepted_error) result)
  -> project_rejection:('rejection -> (Yojson.Safe.t, 'rejection_error) result)
  -> ('accepted, 'rejection) validated_flow_success
  -> ( validated_flow_evidence_snapshot
       , ('accepted_error, 'rejection_error) validated_flow_evidence_projection_error )
       result

val validated_flow_evidence_to_string : validated_flow_evidence_snapshot -> string

val validated_flow_evidence_of_string
  :  string
  -> (validated_flow_evidence_snapshot, validated_flow_evidence_decode_error) result

val validated_flow_evidence_sha256 : validated_flow_evidence_snapshot -> string

val validated_flow_evidence_accepted_domain_sha256
  :  validated_flow_evidence_snapshot
  -> string

val validated_flow_evidence_source_error_to_string
  :  validated_flow_evidence_source_error
  -> string

val validated_flow_evidence_invariant_error_to_string
  :  validated_flow_evidence_invariant_error
  -> string

val validated_flow_evidence_decode_error_to_string
  :  validated_flow_evidence_decode_error
  -> string

type flow_candidate_failure =
  | Flow_candidate_rejected of candidate_rejection_receipt
  | Flow_candidate_execution_failed of
      { candidate : flow_attempt_receipt
      ; cause : execution_error
      }

type generation_dispatch_fact =
  | No_generation_dispatch
  | Generation_dispatch_started

type 'callback_error flow_execution_error =
  | Flow_attempt_already_started of flow_evidence
  | Flow_attempt_start_failed of
      { candidate : flow_candidate_visit
      ; cause : start_attempt_error
      ; evidence : flow_evidence
      }
  | Flow_measurement_start_failed of
      { candidate : flow_candidate_visit
      ; cause : measurement_start_error
      ; evidence : flow_evidence
      }
  | Flow_before_measurement_dispatch_callback_failed of
      { measurement : flow_measurement_receipt
      ; cause : 'callback_error
      ; evidence : flow_evidence
      }
  | Flow_measurement_terminal_callback_failed of
      { measurement : flow_measurement_receipt
      ; cause : 'callback_error
      ; evidence : flow_evidence
      }
  | Flow_before_dispatch_callback_failed of
      { candidate : flow_attempt_receipt
      ; cause : 'callback_error
      ; evidence : flow_evidence
      }
  | Flow_before_advance_callback_failed of
      { failed : flow_candidate_failure
      ; next : flow_candidate_visit
      ; cause : 'callback_error
      ; evidence : flow_evidence
      }
  | Flow_candidates_exhausted of
      { rejection : candidate_rejection_receipt
      ; evidence : flow_evidence
      }
  | Flow_exact_execution_failed of
      { candidate : flow_attempt_receipt
      ; cause : execution_error
      ; evidence : flow_evidence
      }

type ('callback_error, 'rejection) validated_flow_error =
  | Flow_execution_terminal of
      { cause : 'callback_error flow_execution_error
      ; prior_rejections : 'rejection semantic_rejection_receipt list
      }
  | Flow_semantic_candidates_exhausted of
      { rejections : 'rejection semantic_rejection_trace
      ; evidence : flow_evidence
      }

(** Closed fact for the invocation returning the error: whether its one outward
    completion dispatch began. This does not claim provider acceptance, response
    receipt, billing, retryability, failover eligibility, or any Pricing
    decision. *)
val flow_execution_error_generation_dispatch
  :  'callback_error flow_execution_error
  -> generation_dispatch_fact

(** Point-in-time evidence for one affine declared-order flow. The candidate
    snapshot is frozen exactly as supplied by the caller. Progress contains only
    candidates reached so far and remains queryable after cancellation. *)
val flow_attempt_evidence : flow_attempt -> flow_evidence

(** Execute one affine declared-order flow with caller-owned pure semantic
    validation. OAS invokes [validate] exactly once after each successful
    candidate transport. [Reject_and_advance] preserves the opaque evidence and
    moves directly to the predetermined successor without using [before_advance].
    Every candidate performs at most one generation POST. A final semantic
    rejection returns a typed nonempty exhaustion trace. OAS performs no domain
    durable commit, recovery, retirement, or preference update. *)
val execute_flow_once
  :  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:_ Eio.Time.clock
  -> before_measurement_dispatch:
       (flow_measurement_receipt -> (unit, 'callback_error) result)
  -> on_measurement_terminal:(flow_measurement_receipt -> (unit, 'callback_error) result)
  -> before_dispatch:(flow_attempt_receipt -> (unit, 'callback_error) result)
  -> before_advance:
       (failed:flow_candidate_failure
        -> next:flow_candidate_visit
        -> (unit, 'callback_error) result)
  -> validate:(flow_success -> ('accepted, 'rejection) semantic_verdict)
  -> flow_attempt
  -> ( ('accepted, 'rejection) validated_flow_success
       , ('callback_error, 'rejection) validated_flow_error )
       result
