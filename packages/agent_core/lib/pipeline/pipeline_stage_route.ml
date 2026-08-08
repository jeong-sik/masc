open Agent_types

let sdk_error_of_http_error = Http_error_sdk.of_http_error

let notify_attribution callback attribution =
  Option.iter (fun notify -> notify attribution) callback
;;

let binding_identity_error ?on_provider_failure detail =
  let error = Error.Config (InvalidConfig { field = "model_id"; detail }) in
  let detailed = Provider_failure_attribution.of_provider_configuration_error error in
  notify_attribution on_provider_failure detailed.provider_failure;
  detailed.error
;;

let binding_identity_for_call agent provider_config =
  let transport =
    Binding_identity.transport_for_call ~injected:(Option.is_some agent.options.transport)
  in
  Binding_identity.of_provider_config ~transport provider_config
;;

let invalid_request message =
  Error.Api
    (Llm_provider.Retry.InvalidRequest
       { message; reason = Llm_provider.Retry.Unknown_invalid_request })
;;

let input_capacity_error ~binding ~message ~constraint_ ~reason =
  Provider_failure_attribution.of_request_validation_error
    ~binding
    (Error.Api (Llm_provider.Retry.InputCapacity { message; constraint_; reason }))
;;

let measurement_error ~binding ~constraint_ = function
  | Llm_provider.Count_tokens_sync.Input_count_failed
      (Llm_provider.Input_token_count.Transport http_error) ->
    Provider_failure_attribution.of_http_error ~binding http_error
  | Llm_provider.Count_tokens_sync.Input_count_failed
      (Llm_provider.Input_token_count.Unsupported { protocol; model_id }) ->
    (match constraint_ with
     | Some constraint_ ->
       input_capacity_error
         ~binding
         ~message:
           (Printf.sprintf
              "provider-native input measurement %s is unavailable for constrained model \
               %s"
              (Llm_provider.Input_token_count.show_protocol protocol)
              model_id)
         ~constraint_
         ~reason:(Llm_provider.Retry.Token_measurement_unavailable protocol)
     | None ->
       Provider_failure_attribution.of_request_validation_error
         ~binding
         (invalid_request
            (Printf.sprintf
               "provider-native input measurement %s is unsupported for model %s"
               (Llm_provider.Input_token_count.show_protocol protocol)
               model_id)))
  | Llm_provider.Count_tokens_sync.Input_count_failed
      (Llm_provider.Input_token_count.Invalid_response { protocol; model_id; detail }) ->
    Provider_failure_attribution.of_response_parse_error
      ~binding
      (Error.Api
         (Llm_provider.Retry.InvalidRequest
            { message =
                Printf.sprintf
                  "invalid %s input measurement for model %s: %s"
                  (Llm_provider.Input_token_count.show_protocol protocol)
                  model_id
                  detail
            ; reason = Llm_provider.Retry.Json_parse_error
            }))
  | Llm_provider.Count_tokens_sync.Output_token_resolution_failed
      Llm_provider.Types.Required_output_token_ceiling_missing ->
    Provider_failure_attribution.of_request_validation_error
      ~binding
      (invalid_request "prepared request has no effective output-token ceiling")
  | Llm_provider.Count_tokens_sync.Invalid_completion_request detail ->
    Provider_failure_attribution.of_request_validation_error
      ~binding
      (invalid_request ("invalid prepared completion request: " ^ detail))
;;

let fit_error ~binding = function
  | Llm_provider.Complete.Context_limit_unknown { model_id } ->
    Provider_failure_attribution.of_request_validation_error
      ~binding
      (Error.Config
         (InvalidConfig
            { field = "max_context"
            ; detail = Printf.sprintf "model %s has no declared context limit" model_id
            }))
  | Llm_provider.Complete.Invalid_context_limit { model_id; max_context_tokens } ->
    Provider_failure_attribution.of_request_validation_error
      ~binding
      (Error.Config
         (InvalidConfig
            { field = "max_context"
            ; detail =
                Printf.sprintf
                  "model %s declares invalid context limit %d"
                  model_id
                  max_context_tokens
            }))
  | Llm_provider.Complete.Output_reservation_unknown { model_id } ->
    Provider_failure_attribution.of_request_validation_error
      ~binding
      (invalid_request
         (Printf.sprintf "model %s has no effective output-token reservation" model_id))
  | Llm_provider.Complete.Context_window_exceeded
      { input_tokens; reserved_output_tokens; max_context_tokens } ->
    Provider_failure_attribution.of_request_validation_error
      ~binding
      (Error.Api
         (Llm_provider.Retry.ContextOverflow
            { message =
                Printf.sprintf
                  "prepared request requires %d input + %d reserved output tokens, limit \
                   %d"
                  input_tokens
                  reserved_output_tokens
                  max_context_tokens
            ; limit = Some max_context_tokens
            }))
  | Llm_provider.Complete.Serving_constraint_rejected { constraint_; reason } ->
    input_capacity_error
      ~binding
      ~message:"prepared request rejected by resolved serving constraint"
      ~constraint_
      ~reason:(Llm_provider.Retry.Serving_constraint_rejected reason)
;;

let preflight_serving_constraint ~binding ~now_unix_s prepared =
  match Llm_provider.Complete.serving_constraint prepared with
  | None -> Ok ()
  | Some constraint_ ->
    (match Llm_provider.Serving_constraint.check_evidence ~now_unix_s constraint_ with
     | Ok () -> Ok ()
     | Error reason ->
       Error
         (input_capacity_error
            ~binding
            ~message:"resolved serving-constraint evidence is not current"
            ~constraint_
            ~reason:(Llm_provider.Retry.Serving_constraint_rejected reason)))
;;

let enforce_context_fit agent (provider_config : Llm_provider.Provider_config.t) =
  match agent.context_fit_admission with
  | Disabled -> false
  | Enforce_when_supported ->
    Llm_provider.Count_tokens_sync.supports_completion_request_measurement provider_config
    ||
      (match
         Llm_provider.Provider_config.capabilities_for_config_model provider_config
       with
      | Some { Llm_provider.Capabilities.serving_constraint = Some _; _ } -> true
      | Some _ | None -> false)
;;

let finish_call ?on_provider_failure = function
  | Ok response ->
    notify_attribution on_provider_failure None;
    Ok response
  | Error (detailed : Provider_failure_attribution.detailed_error) ->
    notify_attribution on_provider_failure detailed.provider_failure;
    Error detailed.error
;;

let admit_provider_attempt callback binding =
  match callback with
  | None -> Ok ()
  | Some callback -> callback binding
;;

let provider_config_for_turn ?on_provider_failure ~turn_config agent =
  match agent.options.provider_config with
  | Some provider_config ->
    Ok (Agent_turn.provider_config_with_agent_config ~config:turn_config provider_config)
  | None ->
    let error =
      Error.Config
        (Error.InvalidConfig
           { field = "provider_config"
           ; detail = "an exact provider configuration is required"
           })
    in
    let detailed = Provider_failure_attribution.of_provider_configuration_error error in
    notify_attribution on_provider_failure detailed.provider_failure;
    Error detailed.error
;;

let dispatch_sync
      ~sw
      ?clock
      ?(trace_context = [])
      ?on_provider_failure
      ?before_provider_attempt
      ~provider_config
      agent
      (prep : Agent_turn.turn_preparation)
  =
  let ( let* ) = Result.bind in
  let tools = Option.value prep.Agent_turn.tools_json ~default:[] in
  let* binding =
    binding_identity_for_call agent provider_config
    |> Result.map_error (binding_identity_error ?on_provider_failure)
  in
  let* () = admit_provider_attempt before_provider_attempt binding in
  let compatibility_call () =
    Llm_provider.Complete.complete
      ~sw
      ~net:agent.net
      ?clock
      ?transport:agent.options.transport
      ~config:provider_config
      ~messages:prep.Agent_turn.effective_messages
      ~tools
      ~trace_context
      ?body_timeout_s:agent.options.body_timeout_s
      ?request_wire_observer:agent.pre_dispatch_serialization_observer
      ()
    |> Result.map_error (Provider_failure_attribution.of_http_error ~binding)
  in
  let admitted_call () =
    let now_unix_s = int_of_float (Unix.gettimeofday ()) in
    let prepared =
      Llm_provider.Complete.prepare_request
        ~config:provider_config
        ~messages:prep.Agent_turn.effective_messages
        ~tools
        ~trace_context
        ()
    in
    (* Reject an oversized exact completion body, stale/future-dated
         evidence, and an unknown context limit before token measurement.
         All three checks are network-free. *)
    match
      Llm_provider.Complete.admit_request_body ~stream:false prepared
      |> Result.map_error (Provider_failure_attribution.of_http_error ~binding)
    with
    | Error error -> Error error
    | Ok serialized ->
      (match preflight_serving_constraint ~binding ~now_unix_s prepared with
       | Error error -> Error error
       | Ok () ->
         (match Llm_provider.Complete.resolve_context_limit prepared with
          | Error error -> Error (fit_error ~binding error)
          | Ok max_context_tokens ->
            (match
               Llm_provider.Complete.measure_request
                 ~sw
                 ~net:agent.net
                 ?clock
                 ?timeout_s:agent.options.body_timeout_s
                 serialized
             with
             | Error error ->
               Error
                 (measurement_error
                    ~binding
                    ~constraint_:(Llm_provider.Complete.serving_constraint prepared)
                    error)
             | Ok measured ->
               (match
                  Llm_provider.Complete.admit_request
                    ~now_unix_s
                    ~max_context_tokens
                    measured
                with
                | Error error -> Error (fit_error ~binding error)
                | Ok admitted ->
                  Llm_provider.Complete.complete_admitted
                    ~sw
                    ~net:agent.net
                    ?clock
                    ?transport:agent.options.transport
                    admitted
                    ?body_timeout_s:agent.options.body_timeout_s
                    ?request_wire_observer:agent.pre_dispatch_serialization_observer
                    ()
                  |> Result.map_error
                       (Provider_failure_attribution.of_http_error ~binding)))))
  in
  if enforce_context_fit agent provider_config
  then finish_call ?on_provider_failure (admitted_call ())
  else finish_call ?on_provider_failure (compatibility_call ())
;;

let dispatch_stream
      ~sw
      ?clock
      ~provider_config
      agent
      (prep : Agent_turn.turn_preparation)
      ~on_event
      ?capture_id
      ?(trace_context = [])
      ?on_telemetry
      ?on_provider_failure
      ?before_provider_attempt
      ()
  =
  let ( let* ) = Result.bind in
  let tools = Option.value prep.Agent_turn.tools_json ~default:[] in
  let* binding =
    binding_identity_for_call agent provider_config
    |> Result.map_error (binding_identity_error ?on_provider_failure)
  in
  let* () = admit_provider_attempt before_provider_attempt binding in
  let compatibility_call () =
    Llm_provider.Complete.complete_stream
      ~sw
      ~net:agent.net
      ?clock
      ?transport:agent.options.transport
      ?capture_id
      ~config:provider_config
      ~messages:prep.Agent_turn.effective_messages
      ~tools
      ~trace_context
      ~on_event
      ?on_telemetry
      ?stream_idle_timeout_s:agent.options.stream_idle_timeout_s
      ?first_event_timeout_s:agent.options.first_event_timeout_s
      ?body_timeout_s:agent.options.body_timeout_s
      ?request_wire_observer:agent.pre_dispatch_serialization_observer
      ()
    |> Result.map_error (Provider_failure_attribution.of_http_error ~binding)
  in
  let admitted_call () =
    let now_unix_s = int_of_float (Unix.gettimeofday ()) in
    let prepared =
      Llm_provider.Complete.prepare_request
        ~config:provider_config
        ~messages:prep.Agent_turn.effective_messages
        ~tools
        ~trace_context
        ?capture_id
        ?stream_idle_timeout_s:agent.options.stream_idle_timeout_s
        ?first_event_timeout_s:agent.options.first_event_timeout_s
        ?body_timeout_s:agent.options.body_timeout_s
        ()
    in
    (* Keep the streaming final-body admission ahead of every measurement
         round-trip just like the synchronous path. *)
    match
      Llm_provider.Complete.admit_request_body ~stream:true prepared
      |> Result.map_error (Provider_failure_attribution.of_http_error ~binding)
    with
    | Error error -> Error error
    | Ok serialized ->
      (match preflight_serving_constraint ~binding ~now_unix_s prepared with
       | Error error -> Error error
       | Ok () ->
         (match Llm_provider.Complete.resolve_context_limit prepared with
          | Error error -> Error (fit_error ~binding error)
          | Ok max_context_tokens ->
            (match
               Llm_provider.Complete.measure_request
                 ~sw
                 ~net:agent.net
                 ?clock
                 ?timeout_s:agent.options.body_timeout_s
                 serialized
             with
             | Error error ->
               Error
                 (measurement_error
                    ~binding
                    ~constraint_:(Llm_provider.Complete.serving_constraint prepared)
                    error)
             | Ok measured ->
               (match
                  Llm_provider.Complete.admit_request
                    ~now_unix_s
                    ~max_context_tokens
                    measured
                with
                | Error error -> Error (fit_error ~binding error)
                | Ok admitted ->
                  Llm_provider.Complete.complete_stream_admitted
                    ~sw
                    ~net:agent.net
                    ?clock
                    ?transport:agent.options.transport
                    admitted
                    ~on_event
                    ?on_telemetry
                    ?request_wire_observer:agent.pre_dispatch_serialization_observer
                    ()
                  |> Result.map_error
                       (Provider_failure_attribution.of_http_error ~binding)))))
  in
  if enforce_context_fit agent provider_config
  then finish_call ?on_provider_failure (admitted_call ())
  else finish_call ?on_provider_failure (compatibility_call ())
;;
