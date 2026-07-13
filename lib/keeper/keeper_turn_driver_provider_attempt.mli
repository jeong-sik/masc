(** Provider-attempt provenance and health helpers for keeper turn driver. *)

(** {1 Provider SDK error classifiers}
    Re-homed from the deleted runtime attempt FSM (RFC-0206); generic
    provider-error classification, not runtime-specific. *)

val sdk_error_is_hard_quota : Agent_sdk.Error.sdk_error -> bool
val sdk_error_is_max_turns_exceeded : Agent_sdk.Error.sdk_error -> bool
val sdk_error_soft_rate_limited :
  Agent_sdk.Error.sdk_error -> float option option
val sdk_error_runtime_fallback_class :
  Agent_sdk.Error.sdk_error -> string option

val provider_attempt_status_of_result :
  ('a, Agent_sdk.Error.sdk_error) result -> string

val provider_attempt_exception_kind_of_result :
  ('a, Agent_sdk.Error.sdk_error) result -> string option

val provider_attempt_status_and_error_of_exception :
  exn -> string * string

type provider_attempt_provenance =
  { model_source : string
  ; resolved_model_source : string
  ; capability_source : string
  ; fallback_authority : string
  ; provider_source_runtime : string option
  }

val base_provider_attempt_provenance : provider_attempt_provenance

val provider_attempt_provenance_fields :
  provider_attempt_provenance -> (string * Yojson.Safe.t) list

type provider_attempt_started_record =
  { started_provenance : provider_attempt_provenance
  ; started_is_last : bool
  ; started_per_provider_timeout_s : float option
  ; started_attempt_timeout_source : string
  ; started_attempt_watchdog_source : string
  }

type provider_attempt_finished_record =
  { finished_provenance : provider_attempt_provenance
  ; finished_status : string
  ; finished_latency_ms : float
  ; finished_checkpoint_after_present : bool
  ; finished_error : Yojson.Safe.t
  ; finished_exception_kind : string option
  }

val provider_attempt_started_decision :
  provider_attempt_started_record -> Yojson.Safe.t

val provider_attempt_finished_decision :
  provider_attempt_finished_record -> Yojson.Safe.t

val client_capacity_full_decision :
  capacity_key:string -> Yojson.Safe.t

val success_selected_model_raw :
  Runtime_candidate.t -> string option

val runtime_candidate_label : string
