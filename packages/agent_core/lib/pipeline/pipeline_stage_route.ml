open Agent_types

(* The admitted body's serialisation walks every message in the request. An
   agent may carry an executor that runs it elsewhere: the closure reads
   immutable request values and returns a result, and nothing in it needs
   this fiber. *)
let run_serialization agent f =
  match agent.serialization_executor with
  | Some executor -> executor.run f
  | None -> f ()
;;

let core_error_of_http_error = Http_error_agent_core.of_http_error

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

(* This stage refuses a request it will not dispatch: a missing output
   ceiling or reservation, an unsupported measurement, an invalid prepared
   request. No provider read it, so it is not an unknown provider refusal --
   a consumer that answers those by sending less would cut history for a
   request that never left. [Attempt_rejected] says what happened: this
   binding cannot take it, and another declared one may. *)
let rejected_before_dispatch message =
  Error.Api
    (Llm_provider.Retry.InvalidRequest
       { message; reason = Llm_provider.Retry.Attempt_rejected })
;;

let input_capacity_error ~binding ~message ~constraint_ ~reason =
  Provider_failure_attribution.of_request_validation_error
    ~binding
    (Error.Api (Llm_provider.Retry.InputCapacity { message; constraint_; reason }))
;;

let measurement_error ~binding ~constraint_ ~provider = function
  | Llm_provider.Count_tokens_sync.Input_count_failed
      (Llm_provider.Input_token_count.Transport http_error) ->
    Provider_failure_attribution.of_http_error ~binding ~provider http_error
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
         (rejected_before_dispatch
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
      (rejected_before_dispatch "prepared request has no effective output-token ceiling")
  | Llm_provider.Count_tokens_sync.Invalid_completion_request detail ->
    Provider_failure_attribution.of_request_validation_error
      ~binding
      (rejected_before_dispatch ("invalid prepared completion request: " ^ detail))
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
      (rejected_before_dispatch
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

(* The measurement spent the caller's whole window; the next stage is not
   sent. *)
let window_spent_by_the_measurement ~operation ~parameter ~seconds ~phase ~next_stage =
  Llm_provider.Http_client.TimeoutError
    { message =
        Printf.sprintf
          "%s deadline exceeded after %.17gs in the count-tokens request, before the %s \
           was sent (Pipeline_stage_route.%s)"
          parameter
          seconds
          next_stage
          operation
    ; phase
    }
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
  (* Provider label for mapped transport errors: without it every timeout
     reads "Provider 'unknown'" (#28852). *)
  let provider =
    Llm_provider.Provider_config.capability_provider_label provider_config
  in
  let now_unix_s = int_of_float (Unix.gettimeofday ()) in
  let prepared =
    Llm_provider.Complete.prepare_request
      ~config:provider_config
      ~messages:prep.Agent_turn.effective_messages
      ~tools
      ~trace_context
      ()
  in
  let requires_exact_fit =
    match agent.context_fit_admission with
    | Body_only -> Llm_provider.Complete.requires_token_measurement prepared
    | Require_exact_fit -> true
  in
  (* Every provider follows the same prepared-request and exact body-admission
     path. A declared serving constraint or explicit exact-fit policy also
     requires provider-native token evidence; unsupported measurement fails
     closed instead of falling back to a second dispatch path. *)
  let result =
    match
      run_serialization agent (fun () ->
        Llm_provider.Complete.admit_request_body ~stream:false prepared)
      |> Result.map_error (Provider_failure_attribution.of_http_error ~binding ~provider)
    with
    | Error error -> Error error
    | Ok serialized ->
      (match preflight_serving_constraint ~binding ~now_unix_s prepared with
       | Error error -> Error error
       | Ok () when not requires_exact_fit ->
         Llm_provider.Complete.complete_serialized
           ~sw
           ~net:agent.net
           ?clock
           ?transport:agent.options.transport
           serialized
           ?body_timeout_s:agent.options.body_timeout_s
           ?call_timeout_s:agent.options.call_timeout_s
           ?permit_wait:agent.options.permit_wait
           ?request_wire_observer:agent.pre_dispatch_serialization_observer
           ()
         |> Result.map_error (Provider_failure_attribution.of_http_error ~binding ~provider)
       | Ok () ->
         (match Llm_provider.Complete.resolve_context_limit prepared with
          | Error error -> Error (fit_error ~binding error)
          | Ok max_context_tokens ->
            (match
               Llm_provider.Http_client.resolve_explicit_deadline
                 ~operation:"Pipeline_stage_route.dispatch_sync"
                 ~parameter:"call_timeout_s"
                 ~clock
                 ~timeout_s:agent.options.call_timeout_s
             with
             | Error error ->
               Error (Provider_failure_attribution.of_http_error ~binding ~provider error)
             | Ok call_deadline ->
               (* The call deadline is one window from here. The measurement
                  spends from it -- its permit wait and its count round trip
                  -- and the completion spends the rest of it, permit wait
                  included. *)
               let call_window = Llm_provider.Deadline_window.open_ call_deadline in
               let measured =
                 Llm_provider.Complete.measure_request
                   ~sw
                   ~net:agent.net
                   ?clock
                   ?timeout_s:agent.options.body_timeout_s
                   ~next_stage:(Llm_provider.Complete.Completion { call_window })
                   ?permit_wait:agent.options.permit_wait
                   serialized
                 |> Result.map_error
                      (measurement_error
                         ~binding
                         ~constraint_:(Llm_provider.Complete.serving_constraint prepared)
                         ~provider)
               in
               (match measured with
                | Error error -> Error error
                | Ok measured ->
                  (match
                     Llm_provider.Complete.admit_request
                       ~now_unix_s
                       ~max_context_tokens
                       measured
                   with
                   | Error error -> Error (fit_error ~binding error)
                   | Ok admitted ->
                     (match Llm_provider.Deadline_window.remaining call_window with
                      | `Spent seconds ->
                        Error
                          (Provider_failure_attribution.of_http_error
                             ~binding
                             ~provider
                             (window_spent_by_the_measurement
                                ~operation:"dispatch_sync"
                                ~parameter:"call_timeout_s"
                                ~seconds
                                ~phase:Llm_provider.Http_client.Non_streaming_body
                                ~next_stage:"completion"))
                      | `Unbounded | `Remaining _ ->
                        Llm_provider.Complete.complete_admitted
                          ~sw
                          ~net:agent.net
                          ?clock
                          ?transport:agent.options.transport
                          admitted
                          ?body_timeout_s:agent.options.body_timeout_s
                          ~call_window
                          ?permit_wait:agent.options.permit_wait
                          ?request_wire_observer:agent.pre_dispatch_serialization_observer
                          ()
                        |> Result.map_error
                             (Provider_failure_attribution.of_http_error ~binding ~provider)))))))
  in
  finish_call ?on_provider_failure result
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
  (* Provider label for mapped transport errors: without it every timeout
     reads "Provider 'unknown'" (#28852). *)
  let provider =
    Llm_provider.Provider_config.capability_provider_label provider_config
  in
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
  let requires_exact_fit =
    match agent.context_fit_admission with
    | Body_only -> Llm_provider.Complete.requires_token_measurement prepared
    | Require_exact_fit -> true
  in
  let result =
    match
      run_serialization agent (fun () ->
        Llm_provider.Complete.admit_request_body ~stream:true prepared)
      |> Result.map_error (Provider_failure_attribution.of_http_error ~binding ~provider)
    with
    | Error error -> Error error
    | Ok serialized ->
      (match preflight_serving_constraint ~binding ~now_unix_s prepared with
       | Error error -> Error error
       | Ok () when not requires_exact_fit ->
         Llm_provider.Complete.complete_stream_serialized
           ~sw
           ~net:agent.net
           ?clock
           ?admission_timeout_s:agent.options.admission_timeout_s
           ?permit_wait:agent.options.permit_wait
           ?transport:agent.options.transport
           serialized
           ~on_event
           ?on_telemetry
           ?request_wire_observer:agent.pre_dispatch_serialization_observer
           ()
         |> Result.map_error (Provider_failure_attribution.of_http_error ~binding ~provider)
       | Ok () ->
         (match Llm_provider.Complete.resolve_context_limit prepared with
          | Error error -> Error (fit_error ~binding error)
          | Ok max_context_tokens ->
            (match
               Llm_provider.Http_client.resolve_explicit_deadline
                 ~operation:"Pipeline_stage_route.dispatch_stream"
                 ~parameter:"admission_timeout_s"
                 ~clock
                 ~timeout_s:agent.options.admission_timeout_s
             with
             | Error error ->
               Error (Provider_failure_attribution.of_http_error ~binding ~provider error)
             | Ok admission_deadline ->
               (* Two of the stream's budgets are one window from here. The
                  admission budget spans both permit waits, the measurement's
                  and the stream's, and the count round trip between them,
                  which runs under what the budget has left. The first-event budget is provider silence
                  before the first token: the count round trip spends from
                  it, and the stream arms what that left; permit waits are
                  queueing and spend none of it. *)
               let admission_window = Llm_provider.Deadline_window.open_ admission_deadline in
               let measured =
                 Llm_provider.Complete.measure_request
                   ~sw
                   ~net:agent.net
                   ?clock
                   ?timeout_s:agent.options.body_timeout_s
                   ~next_stage:
                     (Llm_provider.Complete.Stream
                        { admission_window
                        ; first_event_timeout_s = agent.options.first_event_timeout_s
                        })
                   ?permit_wait:agent.options.permit_wait
                   serialized
                 |> Result.map_error
                      (measurement_error
                         ~binding
                         ~constraint_:(Llm_provider.Complete.serving_constraint prepared)
                         ~provider)
               in
               (match measured with
                | Error error -> Error error
                | Ok measured ->
                  (* Fit first, as [dispatch_sync] does: a request that does
                     not fit is refused as such however the windows stand,
                     not reported as a timeout the caller would retry. *)
                  (match
                     Llm_provider.Complete.admit_request
                       ~now_unix_s
                       ~max_context_tokens
                       measured
                   with
                   | Error error -> Error (fit_error ~binding error)
                   | Ok admitted ->
                     let first_event_left =
                       match
                         ( agent.options.first_event_timeout_s
                         , Llm_provider.Complete.count_round_trip_s measured )
                       with
                       | None, _ -> Ok None
                       | Some budget_s, None ->
                         (* Not timed: no clock, and the stream stage refuses
                            the budget as unenforceable itself. *)
                         Ok (Some budget_s)
                       | Some budget_s, Some spent_s ->
                         let left_s = budget_s -. spent_s in
                         if Float.compare left_s 0.0 <= 0
                         then
                           Error
                             (window_spent_by_the_measurement
                                ~operation:"dispatch_stream"
                                ~parameter:"first_event_timeout_s"
                                ~seconds:budget_s
                                ~phase:Llm_provider.Http_client.First_token
                                ~next_stage:"stream")
                         else Ok (Some left_s)
                     in
                     let admission_unspent =
                       match Llm_provider.Deadline_window.remaining admission_window with
                       | `Unbounded | `Remaining _ -> Ok ()
                       | `Spent seconds ->
                         Error
                           (window_spent_by_the_measurement
                              ~operation:"dispatch_stream"
                              ~parameter:"admission_timeout_s"
                              ~seconds
                              ~phase:Llm_provider.Http_client.Queue
                              ~next_stage:"stream")
                     in
                     (match first_event_left, admission_unspent with
                      | Error error, _ | Ok _, Error error ->
                        Error (Provider_failure_attribution.of_http_error ~binding ~provider error)
                      | Ok first_event_timeout_s, Ok () ->
                        let admitted =
                          match first_event_timeout_s with
                          | None -> admitted
                          | Some first_event_timeout_s ->
                            Llm_provider.Complete.with_first_event_timeout_s
                              first_event_timeout_s
                              admitted
                        in
                        Llm_provider.Complete.complete_stream_admitted
                          ~sw
                          ~net:agent.net
                          ?clock
                          ~admission_window
                          ?permit_wait:agent.options.permit_wait
                          ?transport:agent.options.transport
                          admitted
                          ~on_event
                          ?on_telemetry
                          ?request_wire_observer:agent.pre_dispatch_serialization_observer
                          ()
                        |> Result.map_error
                             (Provider_failure_attribution.of_http_error ~binding ~provider)))))))
  in
  finish_call ?on_provider_failure result
;;

let%test "a refusal this stage makes before dispatch is Attempt_rejected" =
  let config =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Anthropic
      ~model_id:"model"
      ~base_url:"https://example.test"
      ()
  in
  match
    Binding_identity.of_provider_config
      ~transport:(Binding_identity.transport_for_call ~injected:false)
      config
  with
  | Error _ -> false
  | Ok binding ->
    (match
       (fit_error ~binding
          (Llm_provider.Complete.Output_reservation_unknown { model_id = "model" }))
         .Provider_failure_attribution.error
     with
     | Error.Api
         (Llm_provider.Retry.InvalidRequest
            { reason = Llm_provider.Retry.Attempt_rejected; _ }) -> true
     | _ -> false)
;;
