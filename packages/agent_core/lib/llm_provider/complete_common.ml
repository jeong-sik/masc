(** Internal helpers shared between sync and streaming completion paths.

    Extracted from {!Complete} to keep the main module focused on
    HTTP request/response orchestration.

    @since 0.205.9 *)

type capability_source =
  | Model_capability
  | Provider_default_capability

let capability_source_to_string = function
  | Model_capability -> "model"
  | Provider_default_capability -> "provider_default"
;;

let base_capabilities_for_kind = function
  | Provider_config.Ollama -> Capabilities.ollama_capabilities
  | DashScope -> Capabilities.dashscope_capabilities
  | Anthropic -> Capabilities.anthropic_capabilities
  | Kimi -> Capabilities.kimi_capabilities
  | Glm -> Capabilities.glm_capabilities
  | Gemini -> Capabilities.gemini_capabilities
  | OpenAI_compat -> Capabilities.openai_compat_chat_capabilities
;;

let resolve_capabilities_for_config (config : Provider_config.t) =
  match Provider_config.capabilities_for_config_model config with
  | Some caps -> caps, Model_capability
  | None -> base_capabilities_for_kind config.kind, Provider_default_capability
;;

let warn_on_drift_observation source = function
  | Capabilities.Thinking_returned_but_declared_unsupported ->
    (match source with
     | Model_capability -> true
     | Provider_default_capability -> false)
  | Capabilities.Usage_missing_but_declared
  | Capabilities.Tools_used_but_declared_unsupported
  | Capabilities.Stop_tool_use_but_declared_unsupported -> true
;;

let partition_drift_observations source observations =
  List.fold_right
    (fun observation (warn_observations, info_observations) ->
       if warn_on_drift_observation source observation
       then observation :: warn_observations, info_observations
       else warn_observations, observation :: info_observations)
    observations
    ([], [])
;;

let capability_observation_payload
      ~(event : string)
      ~(confidence : string)
      ~(source : capability_source)
      ~(config : Provider_config.t)
      observations
  =
  `Assoc
    [ "event", `String event
    ; "model", `String config.model_id
    ; "provider", `String (Provider_config.show_provider_kind config.kind)
    ; "capability_source", `String (capability_source_to_string source)
    ; "confidence", `String confidence
    ; ( "observations"
      , `List
          (List.map
             (fun observation ->
                `String (Capabilities.show_drift_observation observation))
             observations) )
    ]
  |> Yojson.Safe.to_string
;;

let emit_capability_observations ~config ~source observations =
  let warn_observations, info_observations =
    partition_drift_observations source observations
  in
  (match warn_observations with
   | [] -> ()
   | observations ->
     Diag.warn
       "complete"
       "%s"
       (capability_observation_payload
          ~event:"capability_drift"
          ~confidence:"high"
          ~source
          ~config
          observations));
  match info_observations with
  | [] -> ()
  | observations ->
    Diag.info
      "complete"
      "%s"
      (capability_observation_payload
         ~event:"capability_observation"
         ~confidence:"low"
         ~source
         ~config
         observations)
;;

let%test "provider-default thinking drift is low-confidence observation" =
  let warn_observations, info_observations =
    partition_drift_observations
      Provider_default_capability
      [ Capabilities.Thinking_returned_but_declared_unsupported
      ; Capabilities.Tools_used_but_declared_unsupported
      ]
  in
  warn_observations = [ Capabilities.Tools_used_but_declared_unsupported ]
  && info_observations = [ Capabilities.Thinking_returned_but_declared_unsupported ]
;;

let%test "model capability thinking drift remains high-confidence warning" =
  let warn_observations, info_observations =
    partition_drift_observations
      Model_capability
      [ Capabilities.Thinking_returned_but_declared_unsupported ]
  in
  warn_observations = [ Capabilities.Thinking_returned_but_declared_unsupported ]
  && info_observations = []
;;

let%test "capability source is model when native catalog resolves config model" =
  let config =
    Provider_config.make
      ~kind:Provider_config.Glm
      ~model_id:"glm-5"
      ~base_url:Zai_catalog.general_base_url
      ()
  in
  match resolve_capabilities_for_config config with
  | _, Model_capability -> true
  | _, Provider_default_capability -> false
;;

let%test "capability source is provider default when model is unknown" =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"not-in-model-catalog-xyz"
      ~base_url:"https://example.invalid/v1"
      ()
  in
  match resolve_capabilities_for_config config with
  | caps, Provider_default_capability ->
    caps.supports_tools = Capabilities.openai_compat_chat_capabilities.supports_tools
    && caps.thinking_control_format
       = Capabilities.openai_compat_chat_capabilities.thinking_control_format
  | _, Model_capability -> false
;;

type latency_counter =
  | Unknown_latency
  | Monotonic_latency of Mtime_clock.counter
  | Eio_clock_latency :
      { clock : 'a Eio.Time.clock
      ; started_s : float
      }
      -> latency_counter

let ns_per_ms = 1_000_000.0
let clamp_latency_ms ms = Float.max 0.0 ms

let start_monotonic_latency counter =
  try Monotonic_latency (counter ()) with
  | exn ->
    Reserved_exn.reraise_if_reserved exn;
    Diag.warn
      "complete"
      "monotonic latency clock unavailable: %s"
      (Printexc.to_string exn);
    Unknown_latency
;;

let start_latency_counter ?clock () =
  match clock with
  | Some clock -> Eio_clock_latency { clock; started_s = Eio.Time.now clock }
  | None -> start_monotonic_latency Mtime_clock.counter
;;

let%test "ordinary monotonic clock failure degrades to unknown latency" =
  Diag.with_sink
    (fun _level ~ctx:_ _message -> ())
    (fun () ->
       match start_monotonic_latency (fun () -> raise Exit) with
       | Unknown_latency -> true
       | Monotonic_latency _ | Eio_clock_latency _ -> false)
;;

let%test "reserved monotonic clock failure propagates" =
  match start_monotonic_latency (fun () -> raise Sys.Break) with
  | Unknown_latency | Monotonic_latency _ | Eio_clock_latency _ -> false
  | exception Sys.Break -> true
;;

let latency_ms_float = function
  | Unknown_latency -> None
  | Monotonic_latency counter ->
    Some
      (clamp_latency_ms (Mtime.Span.to_float_ns (Mtime_clock.count counter) /. ns_per_ms))
  | Eio_clock_latency { clock; started_s } ->
    Some (clamp_latency_ms ((Eio.Time.now clock -. started_s) *. 1000.0))
;;

let round_latency_ms ms = int_of_float (Float.round ms)
let latency_ms_int counter = Option.map round_latency_ms (latency_ms_float counter)

(** Enforce the deliverable-assistant-turn policy at completion consumption
    boundaries. Structural parsers and injected transports may legitimately
    assemble [content = []], but production completion entry points must fail
    closed while preserving the typed stop reason. *)
let ensure_nonempty_completion
      (result : (Types.api_response, Http_client.http_error) result)
  =
  match result with
  | Ok ({ content = []; stop_reason; _ } : Types.api_response) ->
    Error (Http_client.empty_completion_error ~stop_reason)
  | Ok _ | Error _ -> result
;;

let%test "latency counter yields non-negative elapsed duration when available" =
  match start_latency_counter () with
  | Unknown_latency -> true
  | counter ->
    (match latency_ms_float counter with
     | Some elapsed_ms -> elapsed_ms >= 0.0
     | None -> false)
;;

let%test "unknown latency counter stays unknown" =
  latency_ms_float Unknown_latency = None && latency_ms_int Unknown_latency = None
;;

let%test "integer latency rounds sub-millisecond samples" =
  round_latency_ms 0.49 = 0 && round_latency_ms 0.5 = 1 && round_latency_ms 0.9 = 1
;;

(** Patch {!Types.api_response} telemetry with transport latency and provider
    metadata.
    The JSON parser sets [request_latency_ms = None] because it cannot see the
    transport round-trip time; this function fills [Some ms] when the transport
    measured one and preserves [None] when latency is genuinely unknown. *)
let patch_telemetry
      (resp : Types.api_response)
      ~(config : Provider_config.t)
      ?(ttfrc_ms : float option = None)
      ?(prefill_ms : float option = None)
      (latency_ms : int option)
  : Types.api_response
  =
  let pk = Some config.kind in
  let model = if String.trim resp.model = "" then config.model_id else resp.model in
  let caps, capability_source = resolve_capabilities_for_config config in
  let ctx_window = caps.max_context_tokens in
  let canonical = Some config.model_id in
  let reasoning_source =
    match Reasoning_dialect.reasoning_source_for_provider_config config with
    | Ok source -> Some source
    | Error detail ->
      invalid_arg ("Complete_common.patch_telemetry: invalid reasoning source: " ^ detail)
  in
  let telemetry =
    match resp.telemetry with
    | Some t ->
      Some
        { t with
          Types.request_latency_ms = latency_ms
        ; provider_kind = pk
        ; canonical_model_id = canonical
        ; reasoning_source
        ; effective_context_window = ctx_window
        ; ttfrc_ms =
            (match ttfrc_ms with
             | Some _ as v -> v
             | None -> t.ttfrc_ms)
        ; prefill_ms =
            (match prefill_ms with
             | Some _ as v -> v
             | None -> t.prefill_ms)
        }
    | None ->
      Some
        { Types.default_inference_telemetry with
          request_latency_ms = latency_ms
        ; provider_kind = pk
        ; canonical_model_id = canonical
        ; reasoning_source
        ; effective_context_window = ctx_window
        ; ttfrc_ms
        ; prefill_ms
        }
  in
  let patched = { resp with model; telemetry } in
  (* S01: Structured drift detection — compare actual response behavior
     against declared capabilities. Emits structured JSON so downstream
     observability can alert on silent capability regressions. *)
  (match Capabilities.detect_drift caps patched with
   | [] -> ()
   | observations ->
     emit_capability_observations ~config ~source:capability_source observations);
  patched
;;

(** Internal helper: canonical provider name for metric labels.
    Kept in sync with the log tag used by the [WARN Complete] line. *)
let provider_name_of_kind : Provider_config.provider_kind -> string = function
  | Ollama -> "ollama"
  | DashScope -> "dashscope"
  | Anthropic -> "anthropic"
  | Kimi -> "kimi"
  | OpenAI_compat -> "openai"
  | Gemini -> "gemini"
  | Glm -> "glm"
;;

let tool_use_count (content : Types.content_block list) =
  List.fold_left
    (fun acc block ->
       match block with
       | Types.ToolUse _ -> acc + 1
       | Text _
       | Thinking _
       | ReasoningDetails _
       | RedactedThinking _
       | ToolResult _
       | Image _
       | Document _
       | Audio _ -> acc)
    0
    content
;;

let emit_tool_call_metrics (metrics : Metrics.t) ~provider ~model_id resp =
  match tool_use_count resp.Types.content with
  | 0 -> ()
  | count -> metrics.on_tool_calls ~provider ~model_id ~count
;;

(* The provider-kind sum currently contains only HTTP-backed transports. Keep
   this exhaustive boundary predicate until the transport type itself carries
   a non-HTTP variant; adding a provider kind then becomes a compiler-visible
   decision instead of silently inheriting a wildcard branch. *)
let requires_non_http_transport = function
  | Provider_config.Anthropic
  | Provider_config.Kimi
  | Provider_config.OpenAI_compat
  | Provider_config.Ollama
  | Provider_config.Gemini
  | Provider_config.Glm
  | Provider_config.DashScope -> false
;;

let validate_output_schema_request (config : Provider_config.t) =
  match Provider_config.validate_output_schema_request config with
  | Ok () -> Ok ()
  | Error reason -> Error (Http_client.AcceptRejected { reason })
;;

let validate_tool_choice_request (config : Provider_config.t) =
  match Provider_config.validate_tool_choice_request config with
  | Ok () -> Ok ()
  | Error reason -> Error (Http_client.AcceptRejected { reason })
;;

let validate_reasoning_effort_request (config : Provider_config.t) =
  match Provider_config.validate_reasoning_effort_request_typed config with
  | Ok () -> Ok ()
  | Error rejection ->
    Error
      (Http_client.AcceptRejected
         { reason =
             Provider_config.reasoning_effort_request_rejection_to_message rejection
         })
;;

let validate_request_path (config : Provider_config.t) =
  match Provider_config.validate_request_path config with
  | Ok () -> Ok ()
  | Error reason -> Error (Http_client.AcceptRejected { reason })
;;

(* RFC-OAS-023 (capability axis) — fail loud when an explicit thinking-control
   request cannot be satisfied by the resolved typed capability contract.

   [No_thinking_control] and [supports_reasoning] are intentionally interpreted
   together, never as independent guesses:
   - [supports_reasoning = true] + [No_thinking_control] is the existing
     declared inherent/default-on contract. Explicit enable is already
     satisfied, while explicit disable is impossible (except the typed GLM
     serializer, which has its own control field).
   - [supports_reasoning = false] + [No_thinking_control] has neither an
     encodable toggle nor a declared inherent-thinking contract. Explicit
     enable must therefore be rejected instead of disappearing from the wire.
   - a concrete [thinking_control_format] is accepted only when the selected
     OpenAI-compatible serializer can emit the corresponding activation field.
     A categorical [Reasoning_effort] dialect therefore also requires an
     explicit effort value; merely naming the dialect emits no wire control.

   Absence remains absence: [enable_thinking = None] never invents a policy.
   Explicit disable on a non-reasoning model remains a satisfied no-op. *)
type thinking_control_request_rejection =
  | Enable_not_declared
  | Enable_not_encodable
  | Disable_not_encodable
  | Request_control_invalid of Reasoning_dialect.request_control_rejection

let openai_compat_request_control_artifact
      ~(caps : Capabilities.capabilities)
      (config : Provider_config.t)
  =
  let dialect = Reasoning_dialect.of_capabilities caps in
  let build request_wire =
    Reasoning_dialect.request_control_fields
      request_wire
      dialect
      ~enable_thinking:config.enable_thinking
      ~preserve_thinking:config.preserve_thinking
      ~thinking_budget:config.thinking_budget
      ~reasoning_effort:config.reasoning_effort
      ()
  in
  match Provider_http_codec.of_config config with
  | Provider_http_codec.Openai_chat -> Some (build Reasoning_dialect.Chat_completions)
  | Provider_http_codec.Openai_responses -> Some (build Reasoning_dialect.Responses)
  | Provider_http_codec.Anthropic_messages
  | Provider_http_codec.Ollama_chat
  | Provider_http_codec.Gemini_generate_content
  | Provider_http_codec.Glm_chat -> None
;;

let thinking_control_request_rejection
      ?anthropic_thinking_control
      ~(caps : Capabilities.capabilities)
      (config : Provider_config.t)
  =
  match config.enable_thinking, caps.thinking_control_format with
  | None, _ -> None
  | Some true, thinking_control_format ->
    (match config.kind with
     | Provider_config.OpenAI_compat ->
       (match openai_compat_request_control_artifact ~caps config with
        | None -> Some Enable_not_encodable
        | Some (Error rejection) -> Some (Request_control_invalid rejection)
        | Some (Ok artifact) ->
          (match artifact.Reasoning_dialect.explicit_enable_receipt with
           | Reasoning_dialect.Explicit_enable_encoded _ -> None
           | Reasoning_dialect.Explicit_enable_not_requested -> Some Enable_not_encodable
           | Reasoning_dialect.Explicit_enable_not_encoded ->
             (match thinking_control_format, caps.supports_reasoning with
              | Capabilities.No_thinking_control, true -> None
              | Capabilities.No_thinking_control, false -> Some Enable_not_declared
              | ( ( Capabilities.Thinking_object
                  | Capabilities.Thinking_object_adaptive
                  | Capabilities.Thinking_object_only
                  | Capabilities.Chat_template_kwargs
                  | Capabilities.Chat_template_token _
                  | Capabilities.Ollama_think
                  | Capabilities.Reasoning_effort
                  | Capabilities.Enable_thinking )
                , (false | true) ) -> Some Enable_not_encodable)))
     | Provider_config.Anthropic
     | Provider_config.Kimi
     | Provider_config.Ollama
     | Provider_config.Gemini
     | Provider_config.Glm
     | Provider_config.DashScope -> None)
  | Some false, _ ->
    let disable_not_encodable =
      match config.kind with
      | Provider_config.Anthropic ->
        (match anthropic_thinking_control with
         | Some Capabilities.Anthropic_always_adaptive -> true
         | Some
             ( Capabilities.Anthropic_manual_budget
             | Capabilities.Anthropic_adaptive_default
             | Capabilities.Anthropic_adaptive_preferred
             | Capabilities.Anthropic_adaptive_only ) -> false
         | None ->
           caps.supports_reasoning
           && caps.thinking_control_format = Capabilities.No_thinking_control)
      | Provider_config.Kimi
      | Provider_config.OpenAI_compat
      | Provider_config.Ollama
      | Provider_config.Gemini
      | Provider_config.Glm
      | Provider_config.DashScope ->
        let preserve_wire_encodes_toggle =
          (* backend_openai_request still encodes an explicit thinking toggle
             for rows whose preserve wire is a provider [thinking] object, even
             under [No_thinking_control]. Read from the typed capability, not
             from a provider identity (RFC-OAS-029 S1.1). *)
          Capability_vocab.preserve_wire_owns_thinking_object
            caps.preserve_thinking_control_format
        in
        caps.supports_reasoning
        && caps.thinking_control_format = Capabilities.No_thinking_control
        && not preserve_wire_encodes_toggle
    in
    if disable_not_encodable then Some Disable_not_encodable else None
;;

(* Operator-facing rejection reason for an unsatisfiable thinking-control
   request, or [None] when the request is admissible. Consumed by the Complete
   path ([validate_thinking_control_request], which wraps the reason in a
   typed [Http_client.AcceptRejected]). Until 2026-07-21 this was also shared
   with the legacy public OpenAI-compatible body builder
   ([Api_openai.build_openai_body_result*], removed with the rest of the
   `Api`/`Api_openai`/`Streaming`/`Provider_intf` dispatch island), which kept
   both wire-assembly sites rejecting the identical config with the identical
   message instead of one honoring the [explicit_enable_receipt] and the
   other silently dropping it. *)
let thinking_control_request_rejection_reason
      ?anthropic_thinking_control
      (config : Provider_config.t)
  =
  let caps, _source = resolve_capabilities_for_config config in
  match thinking_control_request_rejection ?anthropic_thinking_control ~caps config with
  | None -> None
  | Some Enable_not_declared ->
    Some
      (Printf.sprintf
         "model %S has no typed capability contract that can satisfy \
          enable_thinking=true: thinking_control_format=No_thinking_control and \
          supports_reasoning=false. Declare the model's exact thinking_control_format, \
          or declare supports_reasoning=true only for a model whose inherent/default-on \
          reasoning contract is verified."
         config.model_id)
  | Some Enable_not_encodable ->
    Some
      (Printf.sprintf
         "model %S declares thinking control, but the resolved typed dialect cannot \
          encode enable_thinking=true on this OpenAI-compatible request path. Use the \
          dialect's explicit control value (for example reasoning_effort), or declare \
          the exact wire dialect for this endpoint."
         config.model_id)
  | Some (Request_control_invalid rejection) ->
    Some (Reasoning_dialect.request_control_rejection_to_message rejection)
  | Some Disable_not_encodable ->
    Some
      (Printf.sprintf
         "model %S is reasoning-capable but its capability record declares \
          thinking_control_format=No_thinking_control: enable_thinking=false cannot be \
          encoded and would be silently dropped, letting the model think freely and \
          corrupt JSON-mode output. Declare a thinking_control_format for this model in \
          Capabilities.for_model_id (models.toml), or route to a model that supports \
          disabling thinking."
         config.model_id)
;;

let validate_thinking_control_request
      ?anthropic_thinking_control
      (config : Provider_config.t)
  =
  match thinking_control_request_rejection_reason ?anthropic_thinking_control config with
  | None -> Ok ()
  | Some reason -> Error (Http_client.AcceptRejected { reason })
;;

(* An admission bound of zero or less would mean "no request may ever
   dispatch" — a config authoring error, not a throttle. Reject it before
   dispatch instead of letting Slot_scheduler.create raise mid-request. *)
let validate_admission_declaration (config : Provider_config.t) =
  match config.max_request_body_bytes with
  | Some n when n < 1 ->
    Error
      (Http_client.AcceptRejected
         { reason =
             Printf.sprintf "max_request_body_bytes must be >= 1 when declared, got %d" n
         })
  | None | Some _ ->
    (match config.max_concurrent_requests with
     | None -> Ok ()
     | Some n when n >= 1 -> Ok ()
     | Some n ->
       Error
         (Http_client.AcceptRejected
            { reason =
                Printf.sprintf
                  "max_concurrent_requests must be >= 1 when declared, got %d"
                  n
            }))
;;

let validate_common (config : Provider_config.t) =
  match validate_request_path config with
  | Error _ as e -> e
  | Ok () ->
    (match validate_output_schema_request config with
     | Error _ as e -> e
     | Ok () ->
       (match validate_tool_choice_request config with
        | Error _ as e -> e
        | Ok () -> validate_reasoning_effort_request config))
;;

let validate_all_with_thinking_control
      ~anthropic_thinking_control
      (config : Provider_config.t)
  =
  match validate_common config with
  | Error _ as e -> e
  | Ok () ->
    (match validate_thinking_control_request ?anthropic_thinking_control config with
     | Error _ as e -> e
     | Ok () -> validate_admission_declaration config)
;;

let validate_all (config : Provider_config.t) =
  match validate_common config with
  | Error _ as e -> e
  | Ok () ->
    (match config.kind with
     | Provider_config.Anthropic ->
       (match Backend_anthropic.validate_nonexact_thinking_controls config with
        | Error reason -> Error (Http_client.AcceptRejected { reason })
        | Ok () -> validate_admission_declaration config)
     | Provider_config.Kimi
     | Provider_config.OpenAI_compat
     | Provider_config.Ollama
     | Provider_config.Gemini
     | Provider_config.Glm
     | Provider_config.DashScope ->
       (match validate_thinking_control_request config with
        | Error _ as e -> e
        | Ok () -> validate_admission_declaration config))
;;

type anthropic_serialization_policy =
  | Frozen_anthropic_thinking_control of Capabilities.anthropic_thinking_control option
  | Resolve_nonexact_anthropic_thinking_control

let serialize_http_request_with_policy
      ~stream
      ~anthropic_serialization_policy
      ~(config : Provider_config.t)
      ~messages
      ~tools
  =
  let http_codec = Provider_http_codec.of_config config in
  let body_result =
    try
      match http_codec with
      | Provider_http_codec.Anthropic_messages ->
        (match
           match anthropic_serialization_policy with
           | Frozen_anthropic_thinking_control anthropic_thinking_control ->
             Backend_anthropic.build_request_artifact_with_thinking_control
               ~anthropic_thinking_control
               ~stream
               ~config
               ~messages
               ~tools
               ()
           | Resolve_nonexact_anthropic_thinking_control ->
             Backend_anthropic.build_request_artifact ~stream ~config ~messages ~tools ()
         with
         | Ok artifact -> Ok (Backend_anthropic.request_payload artifact)
         | Error rejection ->
           Error
             (Http_client.AcceptRejected
                { reason =
                    Backend_anthropic.required_output_token_error_message config rejection
                }))
      | Provider_http_codec.Ollama_chat ->
        Ok (Backend_ollama.build_request ~stream ~config ~messages ~tools ())
      | Provider_http_codec.Openai_responses ->
        Ok (Backend_openai_responses.build_request ~stream ~config ~messages ~tools ())
      | Provider_http_codec.Openai_chat ->
        Ok (Backend_openai.build_request ~stream ~config ~messages ~tools ())
      | Provider_http_codec.Gemini_generate_content ->
        Ok (Backend_gemini.build_request ~stream ~config ~messages ~tools ())
      | Provider_http_codec.Glm_chat ->
        Ok (Backend_glm.build_request ~stream ~config ~messages ~tools ())
    with
    | Invalid_argument reason -> Error (Http_client.AcceptRejected { reason })
  in
  Result.bind body_result (fun body ->
    let actual_bytes = String.length body in
    match config.max_request_body_bytes with
    | Some limit_bytes when actual_bytes > limit_bytes ->
      Error (Http_client.request_body_too_large_error ~actual_bytes ~limit_bytes)
    | None | Some _ -> Ok (http_codec, body))
;;

let serialize_http_request_with_thinking_control
      ~stream
      ~anthropic_thinking_control
      ~config
      ~messages
      ~tools
  =
  serialize_http_request_with_policy
    ~stream
    ~anthropic_serialization_policy:
      (Frozen_anthropic_thinking_control anthropic_thinking_control)
    ~config
    ~messages
    ~tools
;;

let serialize_http_request ~stream ~(config : Provider_config.t) ~messages ~tools =
  serialize_http_request_with_policy
    ~stream
    ~anthropic_serialization_policy:Resolve_nonexact_anthropic_thinking_control
    ~config
    ~messages
    ~tools
;;

let finalize_stream_body ~http_codec body =
  match http_codec with
  | Provider_http_codec.Gemini_generate_content | Provider_http_codec.Openai_responses ->
    body
  | Provider_http_codec.Anthropic_messages | Provider_http_codec.Ollama_chat ->
    Http_client.inject_stream_param body
  | Provider_http_codec.Openai_chat | Provider_http_codec.Glm_chat ->
    (* OpenAI-compatible streaming returns token usage only when the request
       also sets stream_options.include_usage. Anthropic and Ollama carry usage
       natively, so they keep stream:true only. *)
    Http_client.inject_stream_and_options body
;;

(* Serialize the exact body shape used by the built-in HTTP transport without
   applying the declared byte ceiling. Callers either inspect the resulting
   metadata or pass the body through [admit_final_serialized_body] before I/O.
   Clearing the ceiling cannot change provider wire JSON because the field is
   local admission configuration, not a serialized provider parameter. *)
let serialize_final_http_request_unadmitted
      ~stream
      ~(config : Provider_config.t)
      ~messages
      ~tools
  =
  let serialization_config = { config with max_request_body_bytes = None } in
  Result.map
    (fun (http_codec, body) ->
       let body = if stream then finalize_stream_body ~http_codec body else body in
       http_codec, body)
    (serialize_http_request ~stream ~config:serialization_config ~messages ~tools)
;;

(* Streaming serializers may add transport fields after the provider body
   builder returns (for example [stream_options.include_usage]). Recheck the
   caller-declared byte boundary against the exact final body instead of
   assuming the pre-injection measurement is still authoritative. Sync callers
   use the same helper so there is one final-wire admission contract. *)
let admit_final_serialized_body ~(config : Provider_config.t) body =
  let actual_bytes = String.length body in
  match config.max_request_body_bytes with
  | Some limit_bytes when actual_bytes > limit_bytes ->
    Error (Http_client.request_body_too_large_error ~actual_bytes ~limit_bytes)
  | None | Some _ -> Ok body
;;

let observe_pre_dispatch_serialization ?request_wire_observer observation =
  match request_wire_observer with
  | None -> ()
  | Some try_observe ->
    (match Request_wire_observer.observe try_observe observation with
     | Ok () -> ()
     | Error failure ->
       (* Request observation is diagnostic. A full caller-owned queue or an
          ordinary callback bug cannot reinterpret a request that passed typed
          provider admission as a provider failure. *)
       Diag.warn
         "request_wire_observer"
         "pre-dispatch serialization observation was not accepted: %s"
         (Request_wire_observer.show_failure failure))
;;

let observe_request_wire
      ?request_wire_observer
      ~capture_id
      ~(config : Provider_config.t)
      ~http_codec
      ~stream
      ~body
      ()
  =
  let observation =
    Request_wire_observer.observation
      ~capture_id
      ~provider:(Provider_registry.provider_name_of_config config)
      ~model:config.model_id
      ~http_codec:(Provider_http_codec.fingerprint_tag http_codec)
      ~stream
      ~body
  in
  observe_pre_dispatch_serialization ?request_wire_observer observation
;;

(** Strip query string and userinfo from a URL before logging.  A caller-owned
    [Provider_config.t] may contain an arbitrary endpoint; a misconfigured one like
    [https://user:token@api.example.com/v1?token=abc] must not leak the
    secret to stderr. *)
let sanitize_url_for_log url =
  let strip_query s =
    match String.index_opt s '?' with
    | Some i -> String.sub s 0 i
    | None -> s
  in
  let strip_userinfo s =
    (* Only consider the authority segment (between :// and the next /).
       A literal '@' inside a path is allowed and must not be stripped. *)
    match String.index_opt s '/' with
    | None -> s
    | Some i1 when i1 + 2 > String.length s || s.[i1 + 1] <> '/' -> s
    | Some i1 ->
      let authority_start = i1 + 2 in
      let authority_end =
        match String.index_from_opt s authority_start '/' with
        | Some j -> j
        | None -> String.length s
      in
      let authority = String.sub s authority_start (authority_end - authority_start) in
      (match String.rindex_opt authority '@' with
       | None -> s
       | Some k ->
         let host = String.sub authority (k + 1) (String.length authority - k - 1) in
         let prefix = String.sub s 0 authority_start in
         let suffix = String.sub s authority_end (String.length s - authority_end) in
         prefix ^ host ^ suffix)
  in
  strip_query (strip_userinfo url)
;;

let%test "sanitize_url_for_log passthrough plain https" =
  sanitize_url_for_log "https://api.z.ai/api/coding/paas/v4"
  = "https://api.z.ai/api/coding/paas/v4"
;;

let%test "sanitize_url_for_log strips query string" =
  sanitize_url_for_log "https://api.example.com/v1?token=abc"
  = "https://api.example.com/v1"
;;

let%test "sanitize_url_for_log strips userinfo" =
  sanitize_url_for_log "https://user:secret@api.example.com/v1"
  = "https://api.example.com/v1"
;;

let%test "sanitize_url_for_log strips both userinfo and query" =
  sanitize_url_for_log "https://user:token@api.example.com/v1?key=abc"
  = "https://api.example.com/v1"
;;

let%test "sanitize_url_for_log preserves path with literal at-sign" =
  sanitize_url_for_log "https://api.example.com/users/me@org/v1"
  = "https://api.example.com/users/me@org/v1"
;;

let%test "sanitize_url_for_log handles missing path" =
  sanitize_url_for_log "https://api.example.com" = "https://api.example.com"
;;

let http_error_diagnostic_body
      ~provider_name
      ~(config : Provider_config.t)
      ~url
      ~code
      ~(body : string)
  =
  let trimmed = String.trim body in
  if trimmed <> ""
  then Secret_redactor.redact_string body
  else
    Printf.sprintf
      "empty HTTP %d response from provider=%s model=%s base_url=%s request_path=%s \
       url=%s"
      code
      provider_name
      config.model_id
      (sanitize_url_for_log config.base_url)
      (sanitize_url_for_log config.request_path)
      (sanitize_url_for_log url)
;;

let%test "http_error_diagnostic_body preserves non-empty provider body" =
  let config =
    Provider_config.make
      ~kind:Provider_config.Gemini
      ~model_id:"gemini-3-flash-preview"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta/openai"
      ~api_key:"secret"
      ~headers:[]
      ~request_path:"/v1/chat/completions?api_key=secret"
      ()
  in
  http_error_diagnostic_body
    ~provider_name:"gemini"
    ~config
    ~url:
      "https://gen.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=secret"
    ~code:404
    ~body:"model not found"
  = "model not found"
;;

let%test "http_error_diagnostic_body enriches empty provider body" =
  let config =
    Provider_config.make
      ~kind:Provider_config.Gemini
      ~model_id:"gemini-3-flash-preview"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta/openai"
      ~api_key:"secret"
      ~headers:[]
      ~request_path:"/v1/chat/completions?api_key=secret"
      ()
  in
  http_error_diagnostic_body
    ~provider_name:"gemini"
    ~config
    ~url:
      "https://gen.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=secret"
    ~code:404
    ~body:""
  = "empty HTTP 404 response from provider=gemini model=gemini-3-flash-preview \
     base_url=https://generativelanguage.googleapis.com/v1beta/openai \
     request_path=/v1/chat/completions \
     url=https://gen.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent"
;;

let header_name_eq left right =
  String.equal (String.lowercase_ascii left) (String.lowercase_ascii right)
;;

let merge_trace_context_headers headers trace_context =
  match trace_context with
  | [] -> headers
  | _ :: _ ->
    let is_trace_header name =
      List.exists (fun (trace_name, _) -> header_name_eq name trace_name) trace_context
    in
    List.filter (fun (name, _) -> not (is_trace_header name)) headers @ trace_context
;;

let config_with_trace_context config trace_context =
  match trace_context with
  | [] -> config
  | _ :: _ ->
    { config with
      Provider_config.headers =
        merge_trace_context_headers config.Provider_config.headers trace_context
    }
;;
