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
val of_evidence : evidence -> state_diagram_runtime_projection
val state_diagram_runtime_projection_json : state_diagram_runtime_projection -> Yojson.Safe.t
val state_diagram_runtime_fsm_mermaid : state_diagram_runtime_projection -> string
