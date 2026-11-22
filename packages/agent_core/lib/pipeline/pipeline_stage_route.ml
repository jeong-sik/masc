open Agent_types

let _log = Log.create ~module_name:"pipeline_stage_route" ()

(* The admitted body's serialisation walks every message in the request. An
   agent may carry an executor that runs it elsewhere: the closure reads
   immutable request values and returns a result, and nothing in it needs
   this fiber. *)
let run_serialization agent f =
  match agent.serialization_executor with
  | Some executor -> executor.run f
  | None -> f ()
;;

let notify_attribution callback attribution =
  Option.iter (fun notify -> notify attribution) callback
;;

let binding_identity_error ?on_provider_failure detail =
  let error = Error.Config (InvalidConfig { field = "model_id"; detail }) in
  let detailed = Provider_failure_attribution.of_provider_configuration_error error in
  notify_attribution on_provider_failure detailed.provider_failure;
  detailed.error
;;

(* This stage refuses a request it will not dispatch: a missing output
   ceiling or reservation, an unsupported measurement, an invalid prepared
   request, a history the target must receive and cannot read. No provider
   read it, so it is not an unknown provider refusal -- a consumer that
   answers those by sending less would cut history for a request that never
   left. [Attempt_rejected] says what happened: this binding cannot take it,
   and another declared one may. *)
let rejected_before_dispatch message =
  Error.Api
    (Llm_provider.Retry.InvalidRequest
       { message; reason = Llm_provider.Retry.Attempt_rejected })
;;

(* A target that must receive foreign reasoning it cannot read refuses the
   history, not its configuration: the producing source can still send it, so
   the refusal is [Attempt_rejected] for this binding. The other refusals name
   corrupt provenance or a strict caller policy and stay configuration
   errors. *)
let validate_replay_continuity
      ?on_provider_failure ~on_reasoning_replay_exclusion ~binding ~source_change_policy
      ~tools_present ~provider_config messages =
  let module Projection = Llm_provider.Reasoning_history_projection in
  let boundary = Projection.Provider_dispatch {tools_present} in
  match Projection.validate_replay_continuity_for_provider_config
      ~source_change_policy ~boundary provider_config messages with
  | Ok {capability; disposition=Source_change_admitted drops} ->
    on_reasoning_replay_exclusion
      {Projection.boundary; target=capability.target; drops};
    Ok ()
  | Ok {disposition=(Preserve_reasoning | Caller_excluded_reasoning);_} -> Ok ()
  | Error (Projection.Required_reasoning_unreadable _ as refusal) ->
    let detailed = Provider_failure_attribution.of_request_validation_error ~binding
        (rejected_before_dispatch (Projection.error_to_string refusal)) in
    notify_attribution on_provider_failure detailed.provider_failure;
    Error detailed.error
  | Error (( Projection.Invalid_control_lowering _
           | Projection.Invalid_reasoning_target _
           | Projection.Invalid_reasoning_source _
           | Projection.Reasoning_source_on_non_assistant _
           | Projection.Invalid_response_replay _
           | Projection.Unbound_reasoning_artifact _
           | Projection.Incompatible_reasoning_artifact _
           | Projection.Invalid_reasoning_artifact_role _
           | Projection.Unsupported_reasoning_block _ ) as refusal) ->
    let error = Error.Config (InvalidConfig
      {field="reasoning_replay";
       detail=Projection.error_to_string refusal}) in
    let detailed = Provider_failure_attribution.of_provider_configuration_error error in
    notify_attribution on_provider_failure detailed.provider_failure;
    Error detailed.error
;;

let binding_identity_for_call agent provider_config =
  let transport =
    Binding_identity.transport_for_call ~injected:(Option.is_some agent.options.transport)
  in
  Binding_identity.of_provider_config ~transport provider_config
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
    Ok (Agent_turn.provider_config_with_agent_config ~config:turn_config provider_config
        |> Llm_provider.Provider_config.freeze_for_request)
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

(* Local failures before any returned transport outcome retain only a known
   native body. An injected transport owns its own projection. *)
let before_completion agent serialized result =
  match agent.options.transport with
  | None -> Llm_provider.Complete.serialized_outcome serialized result
  | Some _ -> Llm_provider.Completion_outcome.before_serialization result
;;

(* Pre-generation HTTP size refusals eligible for in-run request narrowing.
   Only typed context-overflow and provider body-size refusals qualify; every
   other API, provider, config, or internal error answers immediately. *)
let is_pre_generation_size_refusal = function
  | Error.Api (Llm_provider.Retry.ContextOverflow _)
  | Error.Api
      (Llm_provider.Retry.InvalidRequest
         { reason = Llm_provider.Retry.Request_body_refused_by_provider _; _ }) -> true
  | Error.Api
      ( Llm_provider.Retry.InvalidRequest
          { reason =
              ( Llm_provider.Retry.Json_parse_error
              | Llm_provider.Retry.Attempt_rejected
              | Llm_provider.Retry.Refusal_body_not_received
              | Llm_provider.Retry.Unknown_invalid_request
              | Llm_provider.Retry.Unclassified_status _ )
          ; _
          }
      | Llm_provider.Retry.InputCapacity _
      | Llm_provider.Retry.RateLimited _
      | Llm_provider.Retry.Overloaded _
      | Llm_provider.Retry.ServerError _
      | Llm_provider.Retry.AuthError _
      | Llm_provider.Retry.AuthorizationError _
      | Llm_provider.Retry.PaymentRequired _
      | Llm_provider.Retry.NotFound _
      | Llm_provider.Retry.NetworkError _
      | Llm_provider.Retry.Connect_failed _
      | Llm_provider.Retry.Timeout _ )
  | Error.Provider _
  | Error.Agent _
  | Error.Mcp _
  | Error.Config _
  | Error.Serialization _
  | Error.Io _
  | Error.Orchestration _
  | Error.Media _
  | Error.Internal _
  | Error.Internal_carried _ -> false
;;

let serialized_body_equal left right =
  let prov s = (Llm_provider.Complete.serialized_outcome s ()).request_provenance in
  Llm_provider.Completion_outcome.equal_request_provenance (prov left) (prov right)
;;

type stream_event_class =
  | Generation_event
  | Keepalive_event
  | Deferred_pre_generation_event

(* Narrowing on a live HTTP overflow is only safe before any generated content
   or tool output is emitted. Side-effect-free keepalives ([Connected], [Ping])
   forward immediately; pre-generation envelope/error frames ([MessageStart],
   [MessageDelta], [MessageStop], [SSEError], [NDJSONError], etc.) are buffered
   until either generation begins (flushing in exact order), the attempt answers
   (flushing in exact order), or a narrowed retry replaces this attempt
   (discarding the stale refusal frames so downstream stream bridges stay clean). *)
let classify_stream_event = function
  | Llm_provider.Types.ContentBlockStart _
  | Llm_provider.Types.ContentBlockDelta _
  | Llm_provider.Types.ContentBlockStop _
  | Llm_provider.Types.InlineContentReplay _
  | Llm_provider.Types.ResponsesOutputItems _ -> Generation_event
  | Llm_provider.Types.Connected
  | Llm_provider.Types.Ping -> Keepalive_event
  | Llm_provider.Types.MessageStart _
  | Llm_provider.Types.MessageDelta _
  | Llm_provider.Types.MessageStop
  | Llm_provider.Types.SSEError _
  | Llm_provider.Types.NDJSONError _
  | Llm_provider.Types.SSEParseFailed _
  | Llm_provider.Types.NDJSONParseFailed _
  | Llm_provider.Types.SSEUnknownEventType _
  | Llm_provider.Types.SSEUnsupportedPart _
  | Llm_provider.Types.SSEUnsupportedResponse _
  | Llm_provider.Types.Timeout _
  | Llm_provider.Types.StreamIncomplete _ -> Deferred_pre_generation_event
;;

(* Where a request stands among the turn's requests. The first opens the
   provider attempt and the caller's windows. A narrower one is compared in
   that attempt, spends from the windows the first one opened (when exact-fit
   opened them), and carries the refusal before it with that refusal's body,
   provenance outcome, and any deferred pre-generation stream frames to flush
   if that prior refusal ends up answering the turn. *)
type 'window position =
  | First
  | Narrower of
      { window : 'window option
      ; refused : Llm_provider.Complete.serialized_request
      ; refusal_outcome :
          ( Llm_provider.Types.api_response
            , Provider_failure_attribution.detailed_error )
            result
            Llm_provider.Completion_outcome.t
      ; flush_refusal_events : unit -> unit
      }

(* What one request's way to the provider ended with. [Does_not_fit] is a
   request refused as larger than the input limit before any output or effect
   was produced -- either locally by [admit_request] or by a pre-generation
   HTTP [ContextOverflow] / [Request_body_refused_by_provider] refusal.
   [window] carries what an earlier exact-fit measurement left of the caller's
   windows, or [None] on the body-only path. [flush_refusal_events] flushes any
   buffered pre-generation stream frames from that refused attempt only if its
   [refusal_outcome] ends up answering the route. Every other ending answers
   the route. *)
type ('answer, 'window) request_ending =
  | Answered of 'answer
  | Does_not_fit of
      { refusal : Provider_failure_attribution.detailed_error
      ; serialized : Llm_provider.Complete.serialized_request
      ; refusal_outcome :
          ( Llm_provider.Types.api_response
            , Provider_failure_attribution.detailed_error )
            result
            Llm_provider.Completion_outcome.t
      ; flush_refusal_events : unit -> unit
      ; window : 'window option
      }

(* A narrower request is asked only after the request before it ended as
   [Does_not_fit], front to back, each at most once
   ({!Agent_types.model_input_candidates}). [None] passes the same refusal
   to the next one. *)
let rec next_narrower refusal = function
  | [] -> Ok None
  | (narrow : Agent_turn.narrower_turn_request) :: rest ->
    (match narrow refusal with
     | Error _ as error -> error
     | Ok None -> next_narrower refusal rest
     | Ok (Some request) -> Ok (Some (request, rest)))
;;

(* The turn's requests, compared front to back in the one provider attempt
   the first opened. The answer pairs a response with the request that was
   sent. When the narrower requests run out the last refusal is the answer
   with its original provenance outcome, and a step that fails answers with
   its own error, which no provider made; both keep the refused body as the
   outcome's provenance. A narrower request that fails before it is sent or
   serializes to the identical refused body answers with the refusal before
   it ([send]) and terminates immediately. *)
let rec route_requests agent ?on_provider_failure ~send position
          (request : Agent_turn.turn_request) narrower =
  match send position request with
  | Answered answer ->
    Llm_provider.Completion_outcome.map_result
      (Result.map (fun response -> response, request))
      answer
  | Does_not_fit { refusal; serialized; refusal_outcome; flush_refusal_events; window } ->
    let finish_outcome outcome =
      Llm_provider.Completion_outcome.map_result
        (fun result ->
           finish_call ?on_provider_failure result
           |> Result.map (fun response -> response, request))
        outcome
    in
    (match next_narrower refusal.Provider_failure_attribution.error narrower with
     | Ok (Some (request, narrower)) ->
       route_requests agent ?on_provider_failure ~send
         (Narrower { window; refused = serialized; refusal_outcome; flush_refusal_events })
         request
         narrower
     | Ok None ->
       flush_refusal_events ();
       finish_outcome refusal_outcome
     | Error error ->
       finish_outcome
         (before_completion agent serialized
            (Error { Provider_failure_attribution.error; provider_failure = None })))
;;

let dispatch_sync
      ~sw
      ?clock
      ?(trace_context = [])
      ?on_provider_failure
      ~on_reasoning_replay_exclusion
      ?before_provider_attempt
      ~provider_config
      agent
      (prep : Agent_turn.turn_preparation)
  =
  let ( let* ) result next = match result with
    | Ok value -> next value
    | Error error -> Llm_provider.Completion_outcome.before_serialization (Error error)
  in
  let* binding =
    binding_identity_for_call agent provider_config
    |> Result.map_error (binding_identity_error ?on_provider_failure)
  in
  (* Provider label for mapped transport errors: without it every timeout
     reads "Provider 'unknown'" (#28852). *)
  let provider =
    Llm_provider.Provider_config.capability_provider_label provider_config
  in
  let finish outcome =
    Llm_provider.Completion_outcome.map_result (finish_call ?on_provider_failure) outcome
  in
  let send position (request : Agent_turn.turn_request) =
    Agent_types.set_request_tools agent request.tools;
    let tools = Option.value request.Agent_turn.tools_json ~default:[] in
    (* A narrower request that fails before it is sent is no request. The
       turn ends with the refusal before it, as the turn would end without
       narrower requests; the failure itself goes to the log. *)
    let not_sent ~own error =
      match position with
      | First -> Answered (own ())
      | Narrower { refusal_outcome; flush_refusal_events; _ } ->
        Log.warn
          _log
          "narrower request failed before it was sent; the refusal before it answers"
          [ Log.S ("error", Error.to_string error) ];
        flush_refusal_events ();
        Answered (finish refusal_outcome)
    in
    let ( let* ) result next = match result with
      | Ok value -> next value
      | Error error ->
        not_sent error ~own:(fun () ->
          Llm_provider.Completion_outcome.before_serialization (Error error))
    in
    let* () = validate_replay_continuity
      ?on_provider_failure:(match position with
        | First -> on_provider_failure
        | Narrower _ -> None)
      ~on_reasoning_replay_exclusion
      ~binding ~provider_config
      ~tools_present:(Llm_provider.Complete_common.request_tools_present ~config:provider_config ~tools)
      ~source_change_policy:agent.options.reasoning_source_change
      request.Agent_turn.effective_messages in
    let* () =
      match position with
      | First -> admit_provider_attempt before_provider_attempt binding
      | Narrower _ -> Ok ()
    in
    let now_unix_s = int_of_float (Unix.gettimeofday ()) in
    let prepared =
      Llm_provider.Complete.prepare_request
        ~config:provider_config
        ~messages:request.Agent_turn.effective_messages
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
    match
      run_serialization agent (fun () ->
        Llm_provider.Complete.admit_request_body ~stream:false prepared)
      |> Result.map_error (Provider_failure_attribution.of_http_error ~binding ~provider)
    with
    | Error error ->
      not_sent error.Provider_failure_attribution.error ~own:(fun () ->
        finish (Llm_provider.Completion_outcome.before_serialization (Error error)))
    | Ok serialized ->
      (match position with
       | Narrower { refused; refusal_outcome; _ }
         when serialized_body_equal serialized refused ->
         Log.warn
           _log
           "narrower request produced an identical body; terminating narrowing with prior refusal"
           [];
         Answered (finish refusal_outcome)
       | First | Narrower _ ->
         let failed error =
           not_sent error.Provider_failure_attribution.error ~own:(fun () ->
             finish (before_completion agent serialized (Error error)))
         in
         let sent ~window outcome =
           let mapped =
             Llm_provider.Completion_outcome.map_result
               (Result.map_error
                  (Provider_failure_attribution.of_http_error ~binding ~provider))
               outcome
           in
           match mapped.result with
           | Error refusal
             when is_pre_generation_size_refusal refusal.Provider_failure_attribution.error ->
             Does_not_fit
               { refusal
               ; serialized
               ; refusal_outcome = mapped
               ; flush_refusal_events = (fun () -> ())
               ; window
               }
           | Ok _ | Error _ -> Answered (finish mapped)
         in
         (match preflight_serving_constraint ~binding ~now_unix_s prepared with
          | Error error -> failed error
          | Ok () when not requires_exact_fit ->
            sent
              ~window:None
              (Llm_provider.Complete.complete_serialized
                 ~sw
                 ~net:agent.net
                 ?clock
                 ?transport:agent.options.transport
                 serialized
                 ?body_timeout_s:agent.options.body_timeout_s
                 ?call_timeout_s:agent.options.call_timeout_s
                 ?permit_wait:agent.options.permit_wait
                 ?request_wire_observer:agent.pre_dispatch_serialization_observer
                 ())
          | Ok () ->
            (match Llm_provider.Complete.resolve_context_limit prepared with
             | Error error -> failed (fit_error ~binding error)
             | Ok max_context_tokens ->
               (* The call deadline is one window from the first request. Each
                  measurement spends from it -- its permit wait and its count
                  round trip -- and the completion spends the rest of it,
                  permit wait included. A narrower request spends from the
                  window the first one opened. *)
               let call_window =
                 match position with
                 | Narrower { window = Some call_window; _ } -> Ok call_window
                 | First | Narrower { window = None; _ } ->
                   Llm_provider.Http_client.resolve_explicit_deadline
                     ~operation:"Pipeline_stage_route.dispatch_sync"
                     ~parameter:"call_timeout_s"
                     ~clock
                     ~timeout_s:agent.options.call_timeout_s
                   |> Result.map Llm_provider.Deadline_window.open_
               in
               (match call_window with
                | Error error ->
                  failed (Provider_failure_attribution.of_http_error ~binding ~provider error)
                | Ok call_window ->
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
                   | Error error -> failed error
                   | Ok measured ->
                     (match
                        Llm_provider.Complete.admit_request
                          ~now_unix_s
                          ~max_context_tokens
                          measured
                      with
                      | Error (Llm_provider.Complete.Context_window_exceeded _ as error) ->
                        let refusal = fit_error ~binding error in
                        Does_not_fit
                          { refusal
                          ; serialized
                          ; refusal_outcome = before_completion agent serialized (Error refusal)
                          ; flush_refusal_events = (fun () -> ())
                          ; window = Some call_window
                          }
                      | Error
                          (( Llm_provider.Complete.Context_limit_unknown _
                           | Llm_provider.Complete.Invalid_context_limit _
                           | Llm_provider.Complete.Output_reservation_unknown _
                           | Llm_provider.Complete.Serving_constraint_rejected _ ) as error) ->
                        failed (fit_error ~binding error)
                      | Ok admitted ->
                        (match Llm_provider.Deadline_window.remaining call_window with
                         | `Spent seconds ->
                           failed
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
                           sent
                             ~window:(Some call_window)
                             (Llm_provider.Complete.complete_admitted
                                ~sw
                                ~net:agent.net
                                ?clock
                                ?transport:agent.options.transport
                                admitted
                                ?body_timeout_s:agent.options.body_timeout_s
                                ~call_window
                                ?permit_wait:agent.options.permit_wait
                                ?request_wire_observer:agent.pre_dispatch_serialization_observer
                                ()))))))))
  in
  route_requests agent ?on_provider_failure ~send First
    prep.Agent_turn.request prep.Agent_turn.narrower
;;

(* What the earlier requests of a stream route spent of its budgets: the
   admission window the first one opened, and the seconds their count round
   trips took of the first-event budget. *)
type 'window stream_spent =
  { admission_window : 'window
  ; counted_s : float
  }

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
      ~on_reasoning_replay_exclusion
      ?before_provider_attempt
      ()
  =
  let ( let* ) result next = match result with
    | Ok value -> next value
    | Error error -> Llm_provider.Completion_outcome.before_serialization (Error error)
  in
  let* binding =
    binding_identity_for_call agent provider_config
    |> Result.map_error (binding_identity_error ?on_provider_failure)
  in
  (* Provider label for mapped transport errors: without it every timeout
     reads "Provider 'unknown'" (#28852). *)
  let provider =
    Llm_provider.Provider_config.capability_provider_label provider_config
  in
  let finish outcome =
    Llm_provider.Completion_outcome.map_result (finish_call ?on_provider_failure) outcome
  in
  let first_event_spent_by_counting ~budget_s =
    window_spent_by_the_measurement
      ~operation:"dispatch_stream"
      ~parameter:"first_event_timeout_s"
      ~seconds:budget_s
      ~phase:Llm_provider.Http_client.First_token
      ~next_stage:"stream"
  in
  let send position (request : Agent_turn.turn_request) =
    Agent_types.set_request_tools agent request.tools;
    let tools = Option.value request.Agent_turn.tools_json ~default:[] in
    (* A narrower request that fails before it is sent is no request. The
       turn ends with the refusal before it, as the turn would end without
       narrower requests; the failure itself goes to the log. *)
    let not_sent ~own error =
      match position with
      | First -> Answered (own ())
      | Narrower { refusal_outcome; flush_refusal_events; _ } ->
        Log.warn
          _log
          "narrower request failed before it was sent; the refusal before it answers"
          [ Log.S ("error", Error.to_string error) ];
        flush_refusal_events ();
        Answered (finish refusal_outcome)
    in
    let ( let* ) result next = match result with
      | Ok value -> next value
      | Error error ->
        not_sent error ~own:(fun () ->
          Llm_provider.Completion_outcome.before_serialization (Error error))
    in
    let* () = validate_replay_continuity
      ?on_provider_failure:(match position with
        | First -> on_provider_failure
        | Narrower _ -> None)
      ~on_reasoning_replay_exclusion
      ~binding ~provider_config
      ~tools_present:(Llm_provider.Complete_common.request_tools_present ~config:provider_config ~tools)
      ~source_change_policy:agent.options.reasoning_source_change
      request.Agent_turn.effective_messages in
    let* () =
      match position with
      | First -> admit_provider_attempt before_provider_attempt binding
      | Narrower _ -> Ok ()
    in
    let now_unix_s = int_of_float (Unix.gettimeofday ()) in
    let prepared =
      Llm_provider.Complete.prepare_request
        ~config:provider_config
        ~messages:request.Agent_turn.effective_messages
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
    match
      run_serialization agent (fun () ->
        Llm_provider.Complete.admit_request_body ~stream:true prepared)
      |> Result.map_error (Provider_failure_attribution.of_http_error ~binding ~provider)
    with
    | Error error ->
      not_sent error.Provider_failure_attribution.error ~own:(fun () ->
        finish (Llm_provider.Completion_outcome.before_serialization (Error error)))
    | Ok serialized ->
      (match position with
       | Narrower { refused; refusal_outcome; flush_refusal_events; _ }
         when serialized_body_equal serialized refused ->
         Log.warn
           _log
           "narrower stream request produced an identical body; terminating narrowing with prior refusal"
           [];
         flush_refusal_events ();
         Answered (finish refusal_outcome)
       | First | Narrower _ ->
         let failed error =
           not_sent error.Provider_failure_attribution.error ~own:(fun () ->
             finish (before_completion agent serialized (Error error)))
         in
         let event_emitted = ref false in
         let buffered_pre_gen_events = ref [] in
         let flush_buffered_events () =
           match List.rev !buffered_pre_gen_events with
           | [] -> ()
           | events ->
             buffered_pre_gen_events := [];
             List.iter on_event events
         in
         let observed_on_event ev =
           if !event_emitted
           then on_event ev
           else (
             match classify_stream_event ev with
             | Keepalive_event -> on_event ev
             | Deferred_pre_generation_event ->
               buffered_pre_gen_events := ev :: !buffered_pre_gen_events
             | Generation_event ->
               event_emitted := true;
               flush_buffered_events ();
               on_event ev)
         in
         let sent ~window outcome =
           let mapped =
             Llm_provider.Completion_outcome.map_result
               (Result.map_error
                  (Provider_failure_attribution.of_http_error ~binding ~provider))
               outcome
           in
           match mapped.result with
           | Error refusal
             when (not !event_emitted)
                  && is_pre_generation_size_refusal
                       refusal.Provider_failure_attribution.error ->
             Does_not_fit
               { refusal
               ; serialized
               ; refusal_outcome = mapped
               ; flush_refusal_events = flush_buffered_events
               ; window
               }
           | Ok _ | Error _ ->
             flush_buffered_events ();
             Answered (finish mapped)
         in
         (match preflight_serving_constraint ~binding ~now_unix_s prepared with
          | Error error -> failed error
          | Ok () when not requires_exact_fit ->
            sent
              ~window:None
              (Llm_provider.Complete.complete_stream_serialized
                 ~sw
                 ~net:agent.net
                 ?clock
                 ?admission_timeout_s:agent.options.admission_timeout_s
                 ?permit_wait:agent.options.permit_wait
                 ?transport:agent.options.transport
                 serialized
                 ~on_event:observed_on_event
                 ?on_telemetry
                 ?request_wire_observer:agent.pre_dispatch_serialization_observer
                 ())
          | Ok () ->
            (match Llm_provider.Complete.resolve_context_limit prepared with
             | Error error -> failed (fit_error ~binding error)
             | Ok max_context_tokens ->
               (* Two of the stream's budgets are one window from the first
                  request. The admission budget spans both permit waits, the
                  measurement's and the stream's, and the count round trip
                  between them, which runs under what the budget has left. The
                  first-event budget is provider silence before the first
                  token: the count round trip spends from it, and the stream
                  arms what that left; permit waits are queueing and spend none
                  of it. A narrower request spends from both: the admission
                  window the first one opened, and what every earlier round
                  trip left of the first-event budget. *)
               let spent =
                 match position with
                 | First | Narrower { window = None; _ } ->
                   Llm_provider.Http_client.resolve_explicit_deadline
                     ~operation:"Pipeline_stage_route.dispatch_stream"
                     ~parameter:"admission_timeout_s"
                     ~clock
                     ~timeout_s:agent.options.admission_timeout_s
                   |> Result.map (fun admission_deadline ->
                     { admission_window = Llm_provider.Deadline_window.open_ admission_deadline
                     ; counted_s = 0.0
                     })
                 | Narrower { window = Some spent; _ } ->
                   (match agent.options.first_event_timeout_s with
                    | Some budget_s when Float.compare (budget_s -. spent.counted_s) 0.0 <= 0 ->
                      Error (first_event_spent_by_counting ~budget_s)
                    | Some _ | None -> Ok spent)
               in
               (match spent with
                | Error error ->
                  failed (Provider_failure_attribution.of_http_error ~binding ~provider error)
                | Ok ({ admission_window; counted_s } as spent) ->
                  let measured =
                    Llm_provider.Complete.measure_request
                      ~sw
                      ~net:agent.net
                      ?clock
                      ?timeout_s:agent.options.body_timeout_s
                      ~next_stage:
                        (Llm_provider.Complete.Stream
                           { admission_window
                           ; first_event_timeout_s =
                               Option.map
                                 (fun budget_s -> budget_s -. counted_s)
                                 agent.options.first_event_timeout_s
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
                   | Error error -> failed error
                   | Ok measured ->
                     let counted_s =
                       counted_s
                       +. Option.value (Llm_provider.Complete.count_round_trip_s measured) ~default:0.0
                     in
                     (* Fit first, as [dispatch_sync] does: a request that does
                        not fit is refused as such however the windows stand,
                        not reported as a timeout the caller would retry. *)
                     (match
                        Llm_provider.Complete.admit_request
                          ~now_unix_s
                          ~max_context_tokens
                          measured
                      with
                      | Error (Llm_provider.Complete.Context_window_exceeded _ as error) ->
                        let refusal = fit_error ~binding error in
                        Does_not_fit
                          { refusal
                          ; serialized
                          ; refusal_outcome = before_completion agent serialized (Error refusal)
                          ; flush_refusal_events = (fun () -> ())
                          ; window = Some { spent with counted_s }
                          }
                      | Error
                          (( Llm_provider.Complete.Context_limit_unknown _
                           | Llm_provider.Complete.Invalid_context_limit _
                           | Llm_provider.Complete.Output_reservation_unknown _
                           | Llm_provider.Complete.Serving_constraint_rejected _ ) as error) ->
                        failed (fit_error ~binding error)
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
                          | Some budget_s, Some (_ : float) ->
                            let left_s = budget_s -. counted_s in
                            if Float.compare left_s 0.0 <= 0
                            then Error (first_event_spent_by_counting ~budget_s)
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
                           failed
                             (Provider_failure_attribution.of_http_error ~binding ~provider error)
                         | Ok first_event_timeout_s, Ok () ->
                           let admitted =
                             match first_event_timeout_s with
                             | None -> admitted
                             | Some first_event_timeout_s ->
                               Llm_provider.Complete.with_first_event_timeout_s
                                 first_event_timeout_s
                                 admitted
                           in
                           sent
                             ~window:(Some { spent with counted_s })
                             (Llm_provider.Complete.complete_stream_admitted
                                ~sw
                                ~net:agent.net
                                ?clock
                                ~admission_window
                                ?permit_wait:agent.options.permit_wait
                                ?transport:agent.options.transport
                                admitted
                                ~on_event:observed_on_event
                                ?on_telemetry
                                ?request_wire_observer:agent.pre_dispatch_serialization_observer
                                ()))))))))
  in
  route_requests agent ?on_provider_failure ~send First
    prep.Agent_turn.request prep.Agent_turn.narrower
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
     | Error.Api
         Llm_provider.Retry.(
           InvalidRequest
             { reason =
                 Json_parse_error
                 | Request_body_refused_by_provider _
                 | Refusal_body_not_received
                 | Unknown_invalid_request
                 | Unclassified_status _
             ; _
             }
           | RateLimited _
           | Overloaded _
           | ServerError _
           | AuthError _
           | AuthorizationError _
           | PaymentRequired _
           | NotFound _
           | ContextOverflow _
           | InputCapacity _
           | NetworkError _ | Connect_failed _
           | Timeout _)
     | Error.Provider _
     | Error.Agent _
     | Error.Mcp _
     | Error.Config _
     | Error.Serialization _
     | Error.Io _
     | Error.Orchestration _
     | Error.Media _
     | Error.Internal _
     | Error.Internal_carried _ -> false)
;;
