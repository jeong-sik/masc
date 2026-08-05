(** Provider-attempt provenance and health helpers for keeper turn driver. *)

type provider_attempt_provenance =
  { model_source : string
  ; resolved_model_source : string
  ; capability_source : string
  ; fallback_authority : string
  ; provider_source_runtime : string option
  }

let provider_attempt_provenance_fields p =
  let base =
    [ ("model_source", `String p.model_source)
    ; ("resolved_model_source", `String p.resolved_model_source)
    ; ("capability_source", `String p.capability_source)
    ; ("fallback_authority", `String p.fallback_authority)
    ]
  in
  match p.provider_source_runtime with
  | None -> base
  | Some source_runtime ->
      ("provider_source_runtime", `String source_runtime) :: base

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

let provider_attempt_started_decision record =
  `Assoc
    (provider_attempt_provenance_fields record.started_provenance
     @ [ ("is_last", `Bool record.started_is_last) ])
;;

let provider_attempt_finished_decision record =
  let decision_fields =
    [
      ("latency_ms", `Float record.finished_latency_ms);
      ("checkpoint_after_present", `Bool record.finished_checkpoint_after_present);
      ("error", record.finished_error);
    ]
  in
  let decision_fields =
    provider_attempt_provenance_fields record.finished_provenance @ decision_fields
  in
  let decision_fields =
    match record.finished_exception_kind with
    | None -> decision_fields
    | Some kind -> ("exception_kind", `String kind) :: decision_fields
  in
  `Assoc decision_fields
;;

let success_selected_model_raw candidate =
  Some (Runtime_candidate.model_health_key candidate)

let runtime_candidate_label = "runtime"
