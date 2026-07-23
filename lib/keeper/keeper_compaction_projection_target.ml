type context_window_resolution =
  | Resolved_context_window of int
  | Context_window_not_resolved
  | Invalid_context_window of int

type request =
  { assignment_id : string
  ; resolve_context_window : Runtime.t -> context_window_resolution
  }

let request ~assignment_id ~resolve_context_window =
  { assignment_id; resolve_context_window }
;;

type unavailable =
  | Empty_assignment
  | Assignment_ambiguous of { assignment_id : string }
  | Runtime_unavailable of { runtime_id : string }
  | Context_window_unavailable of { runtime_id : string }
  | Invalid_effective_context_window of
      { runtime_id : string
      ; effective_max_context : int
      }

type exact =
  { runtime_id : string
  ; provider_id : string
  ; protocol : string
  ; oas_provider_kind : string
  ; model_id : string
  ; effective_max_context : int
  }

type evidence =
  | Exact of exact
  | Unavailable of unavailable

let unavailable_to_json = function
  | Empty_assignment -> `Assoc [ "reason", `String "empty_assignment" ]
  | Assignment_ambiguous { assignment_id } ->
    `Assoc
      [ "reason", `String "assignment_ambiguous"
      ; "assignment_id", `String assignment_id
      ]
  | Runtime_unavailable { runtime_id } ->
    `Assoc
      [ "reason", `String "runtime_unavailable"
      ; "runtime_id", `String runtime_id
      ]
  | Context_window_unavailable { runtime_id } ->
    `Assoc
      [ "reason", `String "context_window_unavailable"
      ; "runtime_id", `String runtime_id
      ]
  | Invalid_effective_context_window { runtime_id; effective_max_context } ->
    `Assoc
      [ "reason", `String "invalid_effective_context_window"
      ; "runtime_id", `String runtime_id
      ; "effective_max_context", `Int effective_max_context
      ]
;;

let evidence_to_json = function
  | Exact
      { runtime_id
      ; provider_id
      ; protocol
      ; oas_provider_kind
      ; model_id
      ; effective_max_context
      } ->
    `Assoc
      [ "kind", `String "exact"
      ; "runtime_id", `String runtime_id
      ; "provider_id", `String provider_id
      ; "protocol", `String protocol
      ; "oas_provider_kind", `String oas_provider_kind
      ; "model_id", `String model_id
      ; "effective_max_context", `Int effective_max_context
      ]
  | Unavailable reason ->
    `Assoc
      [ "kind", `String "unavailable"
      ; "detail", unavailable_to_json reason
      ]
;;

type exact_target =
  { evidence : exact
  ; provider_config : Llm_provider.Provider_config.t
  }
[@@warning "-69"]

type t =
  | Exact_target of exact_target
  | Unavailable_target of unavailable

let captured_evidence = function
  | Exact_target target -> Exact target.evidence
  | Unavailable_target reason -> Unavailable reason
;;

let capture_exact effective_max_context (runtime : Runtime.t) =
  if effective_max_context <= 0
  then
    Unavailable_target
      (Invalid_effective_context_window
         { runtime_id = runtime.id; effective_max_context })
  else
    let provider_config =
      { runtime.provider_config with max_context = Some effective_max_context }
    in
    Exact_target
      { evidence =
          { runtime_id = runtime.id
          ; provider_id = runtime.provider.id
          ; protocol = runtime.provider.protocol
          ; oas_provider_kind =
              Llm_provider.Provider_config.string_of_provider_kind
                provider_config.kind
          ; model_id = provider_config.model_id
          ; effective_max_context
          }
      ; provider_config
      }
;;

let capture { assignment_id; resolve_context_window } =
  if String.equal assignment_id ""
  then Unavailable_target Empty_assignment
  else
    match Runtime.resolve_assignment assignment_id with
    | `Lane _ -> Unavailable_target (Assignment_ambiguous { assignment_id })
    | `Missing ->
      Unavailable_target (Runtime_unavailable { runtime_id = assignment_id })
    | `Single_runtime runtime ->
      (match resolve_context_window runtime with
       | Resolved_context_window effective_max_context ->
         capture_exact effective_max_context runtime
       | Context_window_not_resolved ->
         Unavailable_target
           (Context_window_unavailable { runtime_id = runtime.id })
       | Invalid_context_window effective_max_context ->
         Unavailable_target
           (Invalid_effective_context_window
              { runtime_id = runtime.id; effective_max_context }))
;;

type committed =
  { target : t
  ; checkpoint_ref : Keeper_checkpoint_ref.t
  }

let bind_committed_checkpoint checkpoint_ref target = { target; checkpoint_ref }
let committed_evidence committed = captured_evidence committed.target
let checkpoint_ref committed = committed.checkpoint_ref
