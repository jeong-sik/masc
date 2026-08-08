module Sha256 = Digestif.SHA256

type fingerprint = Fingerprint of string

type output_admission_error =
  | Explicit_capability_snapshot_required
  | Unsupported_output_contract of
      { provider_kind : Provider_config.provider_kind
      ; model_id : string
      ; response_format : Types.response_format
      }
  | Unsupported_exact_cross_feature
  | Global_admission_not_allowed
  | Invalid_connect_timeout of float
  | Invalid_body_timeout of float
  | Caller_supplied_header_not_allowed of string
  | Unsupported_image_input
  | Unsupported_document_input
  | Unsupported_audio_input
  | Unsupported_system_prompt
  | Provider_request_rejected of Http_client.http_error
  | Request_body_too_large of
      { actual_bytes : int
      ; limit_bytes : int
      }
  | Request_serialization_rejected of Http_client.http_error

type json_validation_provenance =
  | Json_syntax_validated
  | Provider_schema_requested_client_validation_required

type normalized_output =
  | Text_output of string
  | Json_output of
      { value : Yojson.Safe.t
      ; validation : json_validation_provenance
      }

type output_normalization_error =
  | Incomplete_structured_response of Types.stop_reason
  | Missing_structured_text
  | Ambiguous_structured_text of int
  | Unexpected_structured_content
  | Invalid_json of string

type frozen_wire_request =
  { response_codec : Provider_http_codec.t
  ; provider_kind : Provider_config.provider_kind
  ; url : string
  ; headers : (string * string) list
  ; body : string
  ; body_sha256 : string
  ; max_request_body_bytes : int option
  ; connect_timeout_s : float option
  ; body_timeout_s : float option
  }

type t =
  { response_format : Types.response_format
  ; wire : frozen_wire_request
  ; fingerprint : fingerprint
  }

type preflight =
  { prepared : Prepared_completion_request.t
  ; exact_completion_artifact : Exact_output_count_tokens.exact_completion_artifact option
  ; config : Provider_config.t
  ; capabilities : Capabilities.capabilities
  ; response_format : Types.response_format
  ; wire : frozen_wire_request
  }

type admission_basis =
  | Measured_context_fit of Prepared_completion_request.context_fit
  | Token_measurement_not_required

type finalization_error =
  | Token_measurement_required of Serving_constraint.t
  | Measured_request_mismatch

let fingerprint_to_string (Fingerprint value) = value
let sha256 value = Sha256.(to_hex (digest_string value))

let rec canonical_json = function
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (name, value) -> name, canonical_json value)
       |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List values -> `List (List.map canonical_json values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as scalar -> scalar
;;

let canonical_response_format = function
  | Types.JsonSchema schema -> Types.JsonSchema (canonical_json schema)
  | (Types.Off | Types.JsonMode) as response_format -> response_format
;;

let contract_is_supported
      (config : Provider_config.t)
      (capabilities : Capabilities.capabilities)
  =
  match config.response_format with
  | Types.Off -> true
  | Types.JsonMode ->
    capabilities.supports_response_format_json
    && Provider_http_codec.supports_json_mode (Provider_http_codec.of_config config)
  | Types.JsonSchema _ -> capabilities.supports_structured_output
;;

let timeout_is_valid = function
  | None -> true
  | Some seconds -> Float.is_finite seconds && seconds > 0.0
;;

let content_uses_exact_cross_feature = function
  | Types.ToolUse _
  | Types.ToolResult _
  | Types.Thinking _
  | Types.ReasoningDetails _
  | Types.RedactedThinking _ -> true
  | Types.Text _ | Types.Image _ | Types.Document _ | Types.Audio _ -> false
;;

let contains_reserved_response_phase_metadata metadata =
  List.exists
    (fun (key, _) ->
       String.equal key Backend_openai_responses.response_phase_metadata_key)
    metadata
;;

let uses_anthropic_schema_prefill (config : Provider_config.t) messages =
  match config.kind, config.response_format, List.rev messages with
  | ( Provider_config.Anthropic
    , Types.JsonSchema _
    , ({ role = Types.Assistant; _ } : Types.message) :: _ ) -> true
  | Provider_config.Anthropic, Types.JsonSchema _, _ -> false
  | Provider_config.Anthropic, (Types.Off | Types.JsonMode), _
  | ( ( Provider_config.Kimi
      | Provider_config.OpenAI_compat
      | Provider_config.Ollama
      | Provider_config.Gemini
      | Provider_config.Glm
      | Provider_config.DashScope )
    , _
    , _ ) -> false
;;

let request_uses_exact_cross_feature (request : Llm_transport.completion_request) =
  let config = request.config in
  request.tools <> []
  || config.tool_stream
  || config.disable_parallel_tool_use
  || (match config.tool_choice with
      | None | Some Types.None_ -> false
      | Some _ -> true)
  || Option.is_some config.preserve_thinking
  || Option.is_some config.thinking_budget
  || Option.is_some config.reasoning_effort
  || Option.is_some config.clear_thinking
  || uses_anthropic_schema_prefill config request.messages
  || List.exists
       (fun (message : Types.message) ->
          message.role = Types.Tool
          || contains_reserved_response_phase_metadata message.metadata
          || List.exists content_uses_exact_cross_feature message.content)
       request.messages
;;

let caller_supplied_header_name = function
  | [] -> None
  | (name, _) :: _ -> Some name
;;

let rec content_capability_rejection capabilities = function
  | [] -> None
  | Types.Image _ :: _ when not capabilities.Capabilities.supports_image_input ->
    Some Unsupported_image_input
  | Types.Document _ :: _ when not capabilities.Capabilities.supports_document_input ->
    Some Unsupported_document_input
  | Types.Audio _ :: _ ->
    (* No provider-neutral audio representability contract is frozen into an
       exact plan yet. Generic audio capability alone is insufficient. *)
    Some Unsupported_audio_input
  | Types.ToolResult { content_blocks = Some blocks; _ } :: rest ->
    (match content_capability_rejection capabilities blocks with
     | Some _ as rejection -> rejection
     | None -> content_capability_rejection capabilities rest)
  | ( Types.Text _
    | Types.Thinking _
    | Types.ReasoningDetails _
    | Types.RedactedThinking _
    | Types.ToolUse _
    | Types.ToolResult _
    | Types.Image _
    | Types.Document _ )
    :: rest -> content_capability_rejection capabilities rest
;;

let request_capability_rejection
      (config : Provider_config.t)
      (capabilities : Capabilities.capabilities)
      messages
  =
  let has_system_prompt =
    match config.system_prompt with
    | Some value -> not (Api_common.string_is_blank value)
    | None -> false
  in
  if
    (not capabilities.supports_system_prompt)
    && (has_system_prompt
        || List.exists
             (fun (message : Types.message) -> message.role = Types.System)
             messages)
  then Some Unsupported_system_prompt
  else
    List.find_map
      (fun (message : Types.message) ->
         content_capability_rejection capabilities message.content)
      messages
;;

let add_part buffer value =
  Buffer.add_string buffer (string_of_int (String.length value));
  Buffer.add_char buffer ':';
  Buffer.add_string buffer value
;;

let option_float = function
  | None -> "none"
  | Some value -> Printf.sprintf "some:%.17g" value
;;

let credential_header name =
  List.mem
    (String.lowercase_ascii name)
    [ "authorization"
    ; "proxy-authorization"
    ; "x-api-key"
    ; "x-goog-api-key"
    ; "cookie"
    ; "set-cookie"
    ]
;;

let plan_fingerprint
      ~(config : Provider_config.t)
      ~(capabilities : Capabilities.capabilities)
      ~(wire : frozen_wire_request)
      ~admission_basis
  =
  let material = Buffer.create 512 in
  let version, admission_material =
    match admission_basis with
    | Measured_context_fit fit ->
      ( "oas-exact-output-plan-v2"
      , [ string_of_int fit.input_tokens
        ; string_of_int fit.reserved_output_tokens
        ; string_of_int fit.max_context_tokens
        ] )
    | Token_measurement_not_required -> "oas-exact-output-plan-unmeasured-v1", []
  in
  List.iter
    (add_part material)
    ([ version
     ; Provider_http_codec.fingerprint_tag wire.response_codec
     ; Provider_config.string_of_provider_kind wire.provider_kind
     ; Option.value config.provider_id ~default:""
     ; config.model_id
     ; wire.url
     ; wire.body_sha256
     ; Yojson.Safe.to_string (Types.response_format_to_json config.response_format)
     ; (if capabilities.supports_response_format_json then "1" else "0")
     ; (if capabilities.supports_structured_output then "1" else "0")
     ]
     @ admission_material
     @ (match wire.max_request_body_bytes with
        | None -> []
        | Some limit -> [ "max_request_body_bytes"; string_of_int limit ])
     @ [ option_float wire.connect_timeout_s
       ; option_float wire.body_timeout_s
       ; string_of_int (List.length wire.headers)
       ]);
  List.iter
    (fun (name, value) ->
       add_part material name;
       add_part material (if credential_header name then "<redacted>" else value))
    wire.headers;
  Fingerprint (sha256 (Buffer.contents material))
;;

let freeze_config_response_format (config : Provider_config.t) response_format =
  { config with response_format }
;;

let request_url (config : Provider_config.t) =
  match config.kind with
  | Provider_config.Gemini -> Complete_sampling.gemini_url ~config ~stream:false
  | Provider_config.Anthropic
  | Provider_config.Kimi
  | Provider_config.OpenAI_compat
  | Provider_config.Ollama
  | Provider_config.Glm
  | Provider_config.DashScope -> config.base_url ^ config.request_path
;;

type frozen_serialization =
  { response_codec : Provider_http_codec.t
  ; body : string
  ; exact_completion_artifact : Exact_output_count_tokens.exact_completion_artifact option
  }

let exact_artifact_error (config : Provider_config.t) = function
  | Exact_output_count_tokens.Output_token_resolution_failed error ->
    Provider_request_rejected
      (Http_client.AcceptRejected
         { reason = Backend_anthropic.required_output_token_error_message config error })
  | Exact_output_count_tokens.Invalid_completion_request reason ->
    Request_serialization_rejected (Http_client.AcceptRejected { reason })
  | Exact_output_count_tokens.Input_count_failed _ ->
    Request_serialization_rejected
      (Http_client.AcceptRejected
         { reason = "exact completion artifact rejected a supported measurement wire" })
;;

let freeze_serialization
      ~anthropic_thinking_control
      ~(config : Provider_config.t)
      (request : Llm_transport.completion_request)
  =
  if Exact_output_count_tokens.supports_completion_request_measurement config
  then (
    match
      Exact_output_count_tokens.freeze_exact_completion_artifact
        ~anthropic_thinking_control
        request
    with
    | Error error -> Error (exact_artifact_error config error)
    | Ok exact_completion_artifact ->
      let body =
        Exact_output_count_tokens.exact_completion_generation_body
          exact_completion_artifact
      in
      let actual_bytes = String.length body in
      (match config.max_request_body_bytes with
       | Some limit_bytes when actual_bytes > limit_bytes ->
         Error (Request_body_too_large { actual_bytes; limit_bytes })
       | None | Some _ ->
         Ok
           { response_codec = Provider_http_codec.of_config config
           ; body
           ; exact_completion_artifact = Some exact_completion_artifact
           }))
  else (
    match
      Complete_common.serialize_http_request_with_thinking_control
        ~stream:false
        ~anthropic_thinking_control
        ~config
        ~messages:request.messages
        ~tools:request.tools
    with
    | Error
        (Http_client.ProviderFailure
           { kind = Http_client.Request_body_too_large { actual_bytes; limit_bytes }; _ })
      -> Error (Request_body_too_large { actual_bytes; limit_bytes })
    | Error error -> Error (Request_serialization_rejected error)
    | Ok (response_codec, body) ->
      Ok { response_codec; body; exact_completion_artifact = None })
;;

let preflight
      ~config:(original_config : Provider_config.t)
      ~messages
      ~body_timeout_s
      ~anthropic_thinking_control
  =
  match original_config.model_capabilities_override with
  | None -> Error Explicit_capability_snapshot_required
  | Some capabilities ->
    let response_format = canonical_response_format original_config.response_format in
    let config = freeze_config_response_format original_config response_format in
    let prepared =
      Prepared_completion_request.prepare ~config ~messages ?body_timeout_s ()
    in
    let request = Prepared_completion_request.request prepared in
    let auth_headers = Provider_config.auth_headers_for_config config in
    if request_uses_exact_cross_feature request
    then Error Unsupported_exact_cross_feature
    else if Option.is_some config.max_concurrent_requests
    then Error Global_admission_not_allowed
    else if not (timeout_is_valid config.connect_timeout_s)
    then Error (Invalid_connect_timeout (Option.get config.connect_timeout_s))
    else if not (timeout_is_valid request.body_timeout_s)
    then Error (Invalid_body_timeout (Option.get request.body_timeout_s))
    else if not (contract_is_supported config capabilities)
    then
      Error
        (Unsupported_output_contract
           { provider_kind = config.kind; model_id = config.model_id; response_format })
    else (
      match request_capability_rejection config capabilities request.messages with
      | Some rejection -> Error rejection
      | None ->
        (match caller_supplied_header_name config.headers with
         | Some name -> Error (Caller_supplied_header_not_allowed name)
         | None ->
           (match
              Complete_common.validate_all_with_thinking_control
                ~anthropic_thinking_control
                config
            with
            | Error error -> Error (Provider_request_rejected error)
            | Ok () ->
              (match freeze_serialization ~anthropic_thinking_control ~config request with
               | Error error -> Error error
               | Ok { response_codec; body; exact_completion_artifact } ->
                 let body_sha256 = sha256 body in
                 let headers =
                   auth_headers
                   @ [ "Content-Type", "application/json"
                     ; "Content-Length", string_of_int (String.length body)
                     ]
                 in
                 let wire =
                   { response_codec
                   ; provider_kind = config.kind
                   ; url = request_url config
                   ; headers
                   ; body
                   ; body_sha256
                   ; max_request_body_bytes = config.max_request_body_bytes
                   ; connect_timeout_s = config.connect_timeout_s
                   ; body_timeout_s = request.body_timeout_s
                   }
                 in
                 Ok
                   { prepared
                   ; exact_completion_artifact
                   ; config
                   ; capabilities
                   ; response_format
                   ; wire
                   }))))
;;

let prepared_request (preflight : preflight) = preflight.prepared

let measurement_request (preflight : preflight) =
  match preflight.exact_completion_artifact with
  | Some artifact ->
    Ok (Exact_output_count_tokens.exact_completion_measurement_request artifact)
  | None ->
    Error
      (Exact_output_count_tokens.Input_count_failed
         (Input_token_count.Unsupported
            { protocol = Input_token_count.Anthropic_messages_count_tokens
            ; model_id = preflight.config.model_id
            }))
;;

let serving_constraint (preflight : preflight) =
  Prepared_completion_request.serving_constraint preflight.prepared
;;

let preflight_connect_timeout_s (preflight : preflight) = preflight.wire.connect_timeout_s
let preflight_body_timeout_s (preflight : preflight) = preflight.wire.body_timeout_s
let preflight_request_body_sha256 (preflight : preflight) = preflight.wire.body_sha256

let preflight_request_body_bytes (preflight : preflight) =
  String.length preflight.wire.body
;;

let resolve_context_limit (preflight : preflight) =
  Prepared_completion_request.resolve_context_limit preflight.prepared
;;

let finalize preflight admission_basis =
  let fingerprint =
    plan_fingerprint
      ~config:preflight.config
      ~capabilities:preflight.capabilities
      ~wire:preflight.wire
      ~admission_basis
  in
  { response_format = preflight.response_format; wire = preflight.wire; fingerprint }
;;

let finalize_unmeasured preflight =
  match serving_constraint preflight with
  | Some constraint_ -> Error (Token_measurement_required constraint_)
  | None -> Ok (finalize preflight Token_measurement_not_required)
;;

let finalize_measured preflight admitted =
  let admitted_request = Prepared_completion_request.admitted_request admitted in
  if admitted_request != preflight.prepared
  then Error Measured_request_mismatch
  else
    Ok
      (finalize
         preflight
         (Measured_context_fit (Prepared_completion_request.admitted_fit admitted)))
;;

let fingerprint (plan : t) = plan.fingerprint
let response_format (plan : t) = plan.response_format
let request_body_sha256 (plan : t) = plan.wire.body_sha256
let request_url (plan : t) = plan.wire.url
let request_headers (plan : t) = plan.wire.headers
let request_body (plan : t) = plan.wire.body
let response_codec (plan : t) = plan.wire.response_codec
let provider_kind (plan : t) = plan.wire.provider_kind
let connect_timeout_s (plan : t) = plan.wire.connect_timeout_s
let body_timeout_s (plan : t) = plan.wire.body_timeout_s

let verify_frozen_request (plan : t) =
  String.equal plan.wire.body_sha256 (sha256 plan.wire.body)
;;

let structured_text content =
  let rec loop texts = function
    | [] ->
      (match List.rev texts with
       | [] -> Error Missing_structured_text
       | [ text ] -> Ok text
       | values -> Error (Ambiguous_structured_text (List.length values)))
    | Types.Text text :: rest -> loop (text :: texts) rest
    | (Types.Thinking _ | Types.ReasoningDetails _ | Types.RedactedThinking _) :: rest ->
      loop texts rest
    | ( Types.ToolUse _
      | Types.ToolResult _
      | Types.Image _
      | Types.Document _
      | Types.Audio _ )
      :: _ -> Error Unexpected_structured_content
  in
  loop [] content
;;

let normalize_json validation text =
  try
    let value = Yojson.Safe.from_string text in
    Ok (Json_output { value; validation })
  with
  | Yojson.Json_error detail -> Error (Invalid_json detail)
;;

let normalize_text response_format text =
  match response_format with
  | Types.Off -> Ok (Text_output text)
  | Types.JsonMode -> normalize_json Json_syntax_validated text
  | Types.JsonSchema _ ->
    normalize_json Provider_schema_requested_client_validation_required text
;;

let normalize_response response_format (response : Types.api_response) =
  match response.stop_reason with
  | Types.EndTurn | Types.StopSequence ->
    (match structured_text response.content with
     | Error _ as error -> error
     | Ok text -> normalize_text response_format text)
  | Types.StopToolUse ->
    (match structured_text response.content with
     | Error Unexpected_structured_content as error -> error
     | Ok _
     | Error Missing_structured_text
     | Error (Ambiguous_structured_text _)
     | Error (Incomplete_structured_response _)
     | Error (Invalid_json _) ->
       Error (Incomplete_structured_response response.stop_reason))
  | Types.MaxTokens
  | Types.Refusal
  | Types.ContentFilter
  | Types.RepetitionTruncation
  | Types.PauseTurn
  | Types.Compaction
  | Types.ContextWindowExceeded
  | Types.UnmatchedToolCalls
  | Types.Unknown _ -> Error (Incomplete_structured_response response.stop_reason)
;;

let normalize (plan : t) response = normalize_response plan.response_format response

let%test "JsonMode records syntax-only validation provenance" =
  let response : Types.api_response =
    { id = "json-mode"
    ; model = "fixture"
    ; stop_reason = Types.EndTurn
    ; content = [ Types.Text {|{"accepted":true}|} ]
    ; usage = None
    ; telemetry = None
    }
  in
  match normalize_response Types.JsonMode response with
  | Ok
      (Json_output
         { value = `Assoc [ ("accepted", `Bool true) ]
         ; validation = Json_syntax_validated
         }) -> true
  | Ok _ | Error _ -> false
;;

let%test "canonical fingerprint is sensitive to the frozen response codec" =
  let config =
    Provider_config.make
      ~kind:Provider_config.Anthropic
      ~model_id:"fingerprint-fixture"
      ~base_url:"https://example.test"
      ~request_path:"/v1/messages"
      ~max_tokens:16
      ~response_format:Types.Off
      ()
  in
  let capabilities = Capabilities.anthropic_capabilities in
  let fit : Prepared_completion_request.context_fit =
    { input_tokens = 1; reserved_output_tokens = 16; max_context_tokens = 128 }
  in
  let wire response_codec =
    { response_codec
    ; provider_kind = Provider_config.Anthropic
    ; url = "https://example.test/v1/messages"
    ; headers = [ "Content-Length", "2" ]
    ; body = "{}"
    ; body_sha256 = sha256 "{}"
    ; max_request_body_bytes = None
    ; connect_timeout_s = None
    ; body_timeout_s = None
    }
  in
  let fingerprint response_codec =
    plan_fingerprint
      ~config
      ~capabilities
      ~wire:(wire response_codec)
      ~admission_basis:(Measured_context_fit fit)
    |> fingerprint_to_string
  in
  let v0_220_anthropic_fingerprint =
    "d59eee4e9e01296bdea6b695c0e2d9ad1fcfd1ee5779777124a4379e4bc6d598"
  in
  let anthropic_codec = Provider_http_codec.of_config config in
  let openai_codec =
    Provider_http_codec.of_config
      { config with
        kind = Provider_config.OpenAI_compat
      ; request_path = "/v1/chat/completions"
      }
  in
  fingerprint anthropic_codec <> fingerprint openai_codec
  && String.equal (fingerprint anthropic_codec) v0_220_anthropic_fingerprint
;;
