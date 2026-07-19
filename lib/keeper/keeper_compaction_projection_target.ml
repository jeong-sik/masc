type context_window_resolution =
  | Resolved_context_window of int
  | Context_window_not_resolved
  | Invalid_context_window of int

type request =
  | Resolve_assignment of
      { assignment_id : string
      ; resolve_context_window : Runtime.t -> context_window_resolution
      }
  | Exact_runtime of
      { runtime : Runtime.t
      ; effective_max_context : int
      }

let request ~assignment_id ~resolve_context_window =
  Resolve_assignment { assignment_id; resolve_context_window }
;;

let exact_request ~runtime ~effective_max_context =
  Exact_runtime { runtime; effective_max_context }
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

let object_fields label = function
  | `Assoc fields -> Ok fields
  | json ->
    Error
      (Printf.sprintf
         "%s must be an object (received %s)"
         label
         (Yojson.Safe.to_string json))
;;

let exact_fields label expected fields =
  let actual = List.map fst fields |> List.sort String.compare in
  let expected = List.sort String.compare expected in
  if List.equal String.equal expected actual
  then Ok ()
  else
    Error
      (Printf.sprintf "%s contains an invalid or duplicate field set" label)
;;

let required_string label key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string" label key)
  | None -> Error (Printf.sprintf "%s.%s is missing" label key)
;;

let required_int label key fields =
  match List.assoc_opt key fields with
  | Some (`Int value) -> Ok value
  | Some _ -> Error (Printf.sprintf "%s.%s must be an int" label key)
  | None -> Error (Printf.sprintf "%s.%s is missing" label key)
;;

let required_json label key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s.%s is missing" label key)
;;

let unavailable_of_json json =
  let ( let* ) = Result.bind in
  let label = "compaction projection target detail" in
  let* fields = object_fields label json in
  let* reason = required_string label "reason" fields in
  match reason with
  | "empty_assignment" ->
    let* () = exact_fields label [ "reason" ] fields in
    Ok Empty_assignment
  | "assignment_ambiguous" ->
    let* () = exact_fields label [ "assignment_id"; "reason" ] fields in
    let* assignment_id = required_string label "assignment_id" fields in
    Ok (Assignment_ambiguous { assignment_id })
  | "runtime_unavailable" ->
    let* () = exact_fields label [ "reason"; "runtime_id" ] fields in
    let* runtime_id = required_string label "runtime_id" fields in
    Ok (Runtime_unavailable { runtime_id })
  | "context_window_unavailable" ->
    let* () = exact_fields label [ "reason"; "runtime_id" ] fields in
    let* runtime_id = required_string label "runtime_id" fields in
    Ok (Context_window_unavailable { runtime_id })
  | "invalid_effective_context_window" ->
    let* () =
      exact_fields
        label
        [ "effective_max_context"; "reason"; "runtime_id" ]
        fields
    in
    let* runtime_id = required_string label "runtime_id" fields in
    let* effective_max_context =
      required_int label "effective_max_context" fields
    in
    if effective_max_context <= 0
    then Ok (Invalid_effective_context_window { runtime_id; effective_max_context })
    else Error "invalid effective context evidence must be non-positive"
  | unknown ->
    Error (Printf.sprintf "unknown compaction projection target reason: %s" unknown)
;;

let evidence_of_json json =
  let ( let* ) = Result.bind in
  let label = "compaction projection target" in
  let* fields = object_fields label json in
  let* kind = required_string label "kind" fields in
  match kind with
  | "exact" ->
    let* () =
      exact_fields
        label
        [ "effective_max_context"
        ; "kind"
        ; "model_id"
        ; "oas_provider_kind"
        ; "protocol"
        ; "provider_id"
        ; "runtime_id"
        ]
        fields
    in
    let* runtime_id = required_string label "runtime_id" fields in
    let* provider_id = required_string label "provider_id" fields in
    let* protocol = required_string label "protocol" fields in
    let* oas_provider_kind = required_string label "oas_provider_kind" fields in
    let* model_id = required_string label "model_id" fields in
    let* effective_max_context =
      required_int label "effective_max_context" fields
    in
    if effective_max_context <= 0
    then Error "exact effective context evidence must be positive"
    else
      Ok
        (Exact
           { runtime_id
           ; provider_id
           ; protocol
           ; oas_provider_kind
           ; model_id
           ; effective_max_context
           })
  | "unavailable" ->
    let* () = exact_fields label [ "detail"; "kind" ] fields in
    let* detail = required_json label "detail" fields in
    let* reason = unavailable_of_json detail in
    Ok (Unavailable reason)
  | unknown -> Error (Printf.sprintf "unknown compaction projection kind: %s" unknown)
;;

type exact_target =
  { evidence : exact
  ; provider_config : Llm_provider.Provider_config.t
  }

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

let capture = function
  | Exact_runtime { runtime; effective_max_context } ->
    capture_exact effective_max_context runtime
  | Resolve_assignment { assignment_id; resolve_context_window } ->
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
  | Exact_committed of
      { evidence : exact
      ; checkpoint_ref : Keeper_checkpoint_ref.t
      ; prepared_request : Llm_provider.Complete.prepared_request
      }
  | Unavailable_committed of
      { reason : unavailable
      ; checkpoint_ref : Keeper_checkpoint_ref.t
      }

let provider_config_for_checkpoint
      (provider_config : Llm_provider.Provider_config.t)
      (checkpoint : Agent_sdk.Checkpoint.t)
  =
  let agent_config : Agent_sdk.Types.agent_config =
    { (Agent_sdk.Types.default_config ~model:provider_config.model_id) with
      name = checkpoint.agent_name
    ; system_prompt = checkpoint.system_prompt
    ; max_tokens = provider_config.max_tokens
    ; temperature = checkpoint.temperature
    ; top_p = checkpoint.top_p
    ; top_k = checkpoint.top_k
    ; min_p = checkpoint.min_p
    ; enable_thinking = checkpoint.enable_thinking
    ; preserve_thinking = checkpoint.preserve_thinking
    ; response_format = checkpoint.response_format
    ; thinking_budget = checkpoint.thinking_budget
    ; reasoning_effort = checkpoint.reasoning_effort
    ; tool_choice = checkpoint.tool_choice
    ; disable_parallel_tool_use = checkpoint.disable_parallel_tool_use
    ; cache_system_prompt = checkpoint.cache_system_prompt
    }
  in
  Agent_sdk.Provider.provider_config_with_agent_config
    ~config:agent_config
    provider_config
;;

let bind_committed_checkpoint
      ~(checkpoint : Agent_sdk.Checkpoint.t)
      checkpoint_ref
  = function
  | Unavailable_target reason -> Unavailable_committed { reason; checkpoint_ref }
  | Exact_target { evidence; provider_config } ->
    let config = provider_config_for_checkpoint provider_config checkpoint in
    let tools =
      List.map Agent_sdk.Types.tool_schema_to_json checkpoint.tools
    in
    let prepared_request =
      Llm_provider.Complete.prepare_request
        ~config
        ~messages:checkpoint.messages
        ~tools
        ~capture_id:checkpoint_ref.sha256
        ()
    in
    Exact_committed { evidence; checkpoint_ref; prepared_request }
;;

let committed_evidence = function
  | Exact_committed { evidence; _ } -> Exact evidence
  | Unavailable_committed { reason; _ } -> Unavailable reason
;;

let checkpoint_ref = function
  | Exact_committed { checkpoint_ref; _ }
  | Unavailable_committed { checkpoint_ref; _ } -> checkpoint_ref
;;

type target_unavailable = unavailable

module Fit = struct
  type context =
    { input_tokens : int
    ; reserved_output_tokens : int
    ; max_context_tokens : int
    }

  type unavailable =
    | Projection_target_unavailable of target_unavailable
    | Input_count_failed of Llm_provider.Input_token_count.error
    | Output_token_ceiling_missing
    | Invalid_completion_request of string
    | Context_limit_unknown of { model_id : string }
    | Invalid_context_limit of
        { model_id : string
        ; max_context_tokens : int
        }
    | Output_reservation_unknown of { model_id : string }

  type t =
    | Fits of context
    | Exceeds of context
    | Unavailable of unavailable
end

type fit_evidence =
  { checkpoint_ref : Keeper_checkpoint_ref.t
  ; target : evidence
  ; result : Fit.t
  }

let context_to_json (context : Fit.context) =
  `Assoc
    [ "input_tokens", `Int context.input_tokens
    ; "reserved_output_tokens", `Int context.reserved_output_tokens
    ; "max_context_tokens", `Int context.max_context_tokens
    ]
;;

let json_kind kind fields = `Assoc (("kind", `String kind) :: fields)

let input_count_error_to_json = function
  | Llm_provider.Input_token_count.Unsupported { protocol; model_id } ->
    json_kind
      "unsupported"
      [ "protocol", `String (Llm_provider.Input_token_count.show_protocol protocol)
      ; "model_id", `String model_id
      ]
  | Transport error ->
    json_kind
      "transport"
      [ ( "detail"
        , `String (Llm_provider.Error.(of_http_error error |> to_string)) )
      ]
  | Invalid_response { protocol; model_id; detail } ->
    json_kind
      "invalid_response"
      [ "protocol", `String (Llm_provider.Input_token_count.show_protocol protocol)
      ; "model_id", `String model_id
      ; "detail", `String detail
      ]
;;

let unavailable_to_fit_json = function
  | Fit.Projection_target_unavailable reason ->
    json_kind
      "projection_target_unavailable"
      [ "detail", unavailable_to_json reason ]
  | Input_count_failed error ->
    json_kind "input_count_failed" [ "detail", input_count_error_to_json error ]
  | Output_token_ceiling_missing ->
    json_kind "output_token_ceiling_missing" []
  | Invalid_completion_request detail ->
    json_kind "invalid_completion_request" [ "detail", `String detail ]
  | Context_limit_unknown { model_id } ->
    json_kind "context_limit_unknown" [ "model_id", `String model_id ]
  | Invalid_context_limit { model_id; max_context_tokens } ->
    json_kind
      "invalid_context_limit"
      [ "model_id", `String model_id
      ; "max_context_tokens", `Int max_context_tokens
      ]
  | Output_reservation_unknown { model_id } ->
    json_kind "output_reservation_unknown" [ "model_id", `String model_id ]
;;

let fit_evidence_to_json evidence =
  let checkpoint_ref = evidence.checkpoint_ref in
  let result =
    match evidence.result with
    | Fit.Fits context -> json_kind "fits" [ "context", context_to_json context ]
    | Fit.Exceeds context ->
      json_kind "exceeds" [ "context", context_to_json context ]
    | Fit.Unavailable reason ->
      json_kind "unavailable" [ "reason", unavailable_to_fit_json reason ]
  in
  `Assoc
    [ "checkpoint_ref", Keeper_checkpoint_ref.to_yojson checkpoint_ref
    ; "target", evidence_to_json evidence.target
    ; "result", result
    ]
;;

let context_of_oas (fit : Llm_provider.Complete.context_fit) : Fit.context =
  { input_tokens = fit.input_tokens
  ; reserved_output_tokens = fit.reserved_output_tokens
  ; max_context_tokens = fit.max_context_tokens
  }
;;

let unavailable_of_measurement_error = function
  | Llm_provider.Count_tokens_sync.Input_count_failed error ->
    Fit.Input_count_failed error
  | Output_token_resolution_failed Required_output_token_ceiling_missing ->
    Output_token_ceiling_missing
  | Invalid_completion_request detail -> Invalid_completion_request detail
;;

let measure_checkpoint_fit ?connection_cache ?clock ~sw ~net = function
  | Unavailable_committed { reason; checkpoint_ref } ->
    { checkpoint_ref
    ; target = Unavailable reason
    ; result = Fit.Unavailable (Projection_target_unavailable reason)
    }
  | Exact_committed { evidence; checkpoint_ref; prepared_request } ->
    let result =
      match
        Llm_provider.Complete.measure_request
          ?connection_cache
          ?clock
          ~sw
          ~net
          prepared_request
      with
      | Error error -> Fit.Unavailable (unavailable_of_measurement_error error)
      | Ok measured ->
        (match Llm_provider.Complete.admit_request measured with
         | Ok admitted ->
           Fit.Fits
             (Llm_provider.Complete.admitted_fit admitted |> context_of_oas)
         | Error (Context_window_exceeded fit) ->
           Fit.Exceeds (context_of_oas fit)
         | Error (Context_limit_unknown { model_id }) ->
           Fit.Unavailable (Context_limit_unknown { model_id })
         | Error (Invalid_context_limit { model_id; max_context_tokens }) ->
           Fit.Unavailable
             (Invalid_context_limit { model_id; max_context_tokens })
         | Error (Output_reservation_unknown { model_id }) ->
           Fit.Unavailable (Output_reservation_unknown { model_id }))
    in
    { checkpoint_ref; target = Exact evidence; result }
;;
