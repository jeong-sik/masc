(** Provider-attempt provenance and health helpers for keeper turn driver. *)

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
