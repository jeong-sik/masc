type state_diagram_runtime_projection =
  { runtime_models : string list
  ; last_provider_result : string option
  ; runtime_models_source : string
  ; last_provider_result_source : string
  ; effective_runtime_reason : string option
  }

type evidence =
  | Missing_meta
  | Present_meta of
      { has_last_attempt : bool
      ; runtime_projection_evidence : bool
      ; runtime_projection_source : string
      }

let public_runtime_model_label =
  Boundary_redaction.to_string Boundary_redaction.runtime_model_label
;;

let of_evidence = function
  | Missing_meta ->
    { runtime_models = []
    ; last_provider_result = None
    ; runtime_models_source = "missing_keeper_meta"
    ; last_provider_result_source = "missing_keeper_meta"
    ; effective_runtime_reason = None
    }
  | Present_meta { has_last_attempt; runtime_projection_evidence; runtime_projection_source } ->
    let runtime_model_evidence =
      has_last_attempt || runtime_projection_evidence
    in
    let runtime_models =
      if runtime_model_evidence then [ public_runtime_model_label ] else []
    in
    let last_provider_result, last_provider_result_source =
      if has_last_attempt then
        Some public_runtime_model_label, "keeper_meta.runtime.last_runtime_attempt"
      else
        None, "missing_keeper_meta.runtime.last_runtime_attempt"
    in
    { runtime_models
    ; last_provider_result
    ; runtime_models_source =
        (match has_last_attempt with
         | true -> "keeper_meta.runtime.last_runtime_attempt"
         | false -> runtime_projection_source)
    ; last_provider_result_source
    ; effective_runtime_reason =
        (if runtime_model_evidence then Some "keeper_meta.runtime_evidence" else None)
    }
;;

let state_diagram_runtime_projection_json
    (projection : state_diagram_runtime_projection)
  =
  `Assoc
    [ "runtime_models", Json_util.json_string_list projection.runtime_models
    ; "last_provider_result", Json_util.string_opt_to_json projection.last_provider_result
    ; "runtime_models_source", `String projection.runtime_models_source
    ; "last_provider_result_source", `String projection.last_provider_result_source
    ]
;;

let state_diagram_runtime_fsm_mermaid
    (projection : state_diagram_runtime_projection)
  =
  Keeper_decision_audit.runtime_fsm_to_mermaid
    ~provider_health:[]
    ?effective_runtime_reason:projection.effective_runtime_reason
    ~models:projection.runtime_models
    ~last_provider_result:projection.last_provider_result
    ()
;;
