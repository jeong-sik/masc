(** Provider-attempt provenance and health helpers for keeper turn driver. *)

type provider_attempt_provenance =
  { model_source : string
  ; resolved_model_source : string
  ; capability_source : string
  ; fallback_authority : string
  ; provider_source_runtime : string option
  }

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

val success_selected_model_raw :
  Runtime_candidate.t -> string option

val runtime_candidate_label : string
