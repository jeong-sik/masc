(** Private, normalized durable evidence for one successfully validated exact
    flow.

    This leaf owns no live execution value and does not depend on the
    [Exact_output] facade.  Its sole durable representation is the current
    canonical JSON emitted by [to_string]. *)

type t

type candidate =
  { candidate_id : string
  ; candidate_binding_sha256 : string
  ; catalog_generation_sha256 : string
  ; catalog_evidence_sha256 : string
  }

type assurance =
  | Json_syntax_only
  | Provider_schema_requested

type provenance =
  { source_schema_sha256 : string
  ; effective_schema_sha256 : string option
  ; assurance : assurance
  ; candidate_binding_sha256 : string
  ; catalog_generation_sha256 : string
  ; catalog_evidence_sha256 : string
  }

type measurement_dispatch =
  | No_measurement_dispatch
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
  { dispatch : measurement_dispatch
  ; outcome : measurement_outcome
  }

type admitted =
  { plan_sha256 : string
  ; request_body_sha256 : string
  ; provenance : provenance
  ; measurement : measurement_evidence
  }

type rejected =
  { rejection : Yojson.Safe.t
  ; measurement : measurement_evidence
  }

type admission =
  | Rejected of rejected
  | Admitted of admitted

type measurement =
  { operation_id : string
  ; request_body_sha256 : string
  ; candidate_binding_sha256 : string
  ; catalog_generation_sha256 : string
  ; catalog_evidence_sha256 : string
  ; dispatch : measurement_dispatch
  ; outcome : measurement_outcome
  }

type attempt_phase =
  | Before_dispatch
  | Response_received
  | Terminal

type attempt =
  { call_id : string
  ; plan_sha256 : string
  ; request_body_sha256 : string
  ; candidate_binding_sha256 : string
  ; catalog_generation_sha256 : string
  ; catalog_evidence_sha256 : string
  ; phase : attempt_phase
  ; dispatch_count : int
  ; http_status : int option
  ; provider_trace_sha256 : string option
  ; raw_response_sha256 : string option
  }

type transport_failure =
  | Candidate_rejected
  | Completion_failed_before_dispatch
  | Serialized_request_refused of { http_status : int }
  | Invalid_json_output

type advance =
  { next_ordinal : int
  ; failure : transport_failure
  }

type outcome =
  | Advance of advance
  | Semantic_rejected of
      { projector : Yojson.Safe.t
      ; output_sha256 : string
      }
  | Accepted of
      { projector : Yojson.Safe.t
      ; output_sha256 : string
      }

type step =
  { ordinal : int
  ; admission : admission
  ; measurement : measurement option
  ; attempt : attempt option
  ; outcome : outcome
  }

type invariant_error =
  | Empty_flow_id
  | Empty_declared_candidates
  | Empty_steps
  | Non_canonical_identifier of
      { field : string
      ; ordinal : int option
      }
  | Invalid_sha256 of
      { field : string
      ; ordinal : int option
      }
  | Invalid_http_status of
      { field : string
      ; ordinal : int
      }
  | Duplicate_candidate_id of
      { candidate_id : string
      ; first_position : int
      ; duplicate_position : int
      }
  | Duplicate_call_id of
      { call_id : string
      ; first_ordinal : int
      ; duplicate_ordinal : int
      }
  | Duplicate_measurement_operation_id of
      { operation_id : string
      ; first_ordinal : int
      ; duplicate_ordinal : int
      }
  | More_steps_than_declared_candidates
  | Non_contiguous_step_ordinal of
      { expected : int
      ; actual : int
      }
  | Invalid_measurement_state of { ordinal : int }
  | Measurement_binding_mismatch of { ordinal : int }
  | Rejected_admission_has_attempt of { ordinal : int }
  | Rejected_admission_did_not_advance of { ordinal : int }
  | Admitted_candidate_missing_attempt of { ordinal : int }
  | Attempt_binding_mismatch of { ordinal : int }
  | Invalid_attempt_state of { ordinal : int }
  | Non_adjacent_advance of
      { ordinal : int
      ; next_ordinal : int
      }
  | Advance_failure_mismatch of { ordinal : int }
  | Nonfinal_step_accepted of { ordinal : int }
  | Final_step_not_accepted of { ordinal : int }
  | Invalid_projector_json of
      { ordinal : int
      ; location : string
      }

type decode_error =
  | Malformed_json of string
  | Invalid_fields of
      { path : string
      ; detail : string
      }
  | Invalid_transcript of invariant_error
  | Integrity_mismatch
  | Non_canonical_encoding

(** [create] validates transcript topology in one forward pass. Projector JSON
    is recursively canonicalized and rejected when any object contains a
    duplicate key. *)
val create
  :  flow_id:string
  -> declared_candidates:candidate list
  -> steps:step list
  -> (t, invariant_error) result

(** Canonical current-only JSON. It contains no format, version, migration, or
    legacy discriminator. *)
val to_string : t -> string

(** Decode only an exact canonical value emitted by [to_string]. Missing,
    unknown, duplicate, noncanonical, and internally inconsistent data fails
    closed. No live execution type is reconstructed. *)
val of_string : string -> (t, decode_error) result

(** Integrity digest of the normalized transcript payload. *)
val sha256 : t -> string

(** Digest of the final accepted projector JSON. *)
val accepted_domain_sha256 : t -> string

val invariant_error_to_string : invariant_error -> string
val decode_error_to_string : decode_error -> string
