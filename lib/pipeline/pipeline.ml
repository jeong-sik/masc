(** Six-stage Agent turn pipeline: Input, Parse, Route, Collect, Execute, Output.

    [Output] ([stage_output]) dispatches [Execute] ([stage_execute]) internally
    on StopToolUse, so Execute is a sub-step of Output, not a stage that runs
    between Collect and Output. This matches the dataflow diagram in
    pipeline.mli: [Input] -> [Parse] -> [Route] -> [Collect] -> [Output]. *)

open Types
open Agent_types
open Agent_trace

let _log = Log.create ~module_name:"pipeline" ()

(* Shared with Pipeline_stage_prepare via Pipeline_common (re-raises Eio
   cancellation); the thin wrapper keeps this module's log label. *)
let safe_publish bus event = Pipeline_common.safe_publish ~log:_log bus event

open Result_syntax

type api_strategy =
  | Sync
  | Stream of
      { on_event : Types.sse_event -> unit
      ; on_telemetry : (Llm_provider.Telemetry_event.t -> unit) option
      }

type turn_outcome = Pipeline_terminal_tool.turn_outcome =
  | Complete of Types.api_response
  | ToolsExecuted of checkpoint_stage
  | TerminalToolCompleted of Terminal_tool_receipt.t

let persist_turn_checkpoint_for_state = Pipeline_checkpoint.persist_for_state

let persist_turn_checkpoint agent stage =
  persist_turn_checkpoint_for_state agent stage agent.state
;;

(** Set lifecycle to Ready, invoke BeforeTurn hook, handle elicitation. *)
let stage_input = Pipeline_stage_prepare.stage_input

(* ── Stage 2: Parse ──────────────────────────────────────── *)

let last_tool_results_from = Pipeline_stage_prepare.last_tool_results_from

(** Prepare the turn using current [agent.state.messages] and the given
    [turn_params].  Centralises the [Agent_turn.prepare_turn] parameter
    list to keep preparation behind one typed boundary. *)
let prepare_turn_for_agent = Pipeline_stage_prepare.prepare_turn_for_agent

(** Invoke BeforeTurnParams hook and prepare the immutable per-turn config and
    tools. Returns (turn_preparation, turn_config, turn_params). *)
let stage_parse = Pipeline_stage_prepare.stage_parse

(* ── Stage 3: Route ──────────────────────────────────────── *)

(** Convert [Llm_provider.Http_client.http_error] into the [sdk_error]
    shape the pre-[Complete] dispatch path used to surface (that path,
    formerly [Api.create_message], was removed 2026-07-21). Keeps
    downstream Pipeline/Retry/ContextOverflow handling source-compatible
    now that Sync dispatch routes through {!Llm_provider.Complete.complete}.

    HTTP status codes are re-classified via
    {!Llm_provider.Retry.classify_error} so
    ContextOverflow/RateLimited/etc. still map to the same variants. *)
let sdk_error_of_http_error = Pipeline_stage_route.sdk_error_of_http_error

(** Sync dispatch via {!Llm_provider.Complete.complete}.  Routes all
    provider kinds through the consolidated path so [on_request_end]
    metrics fire and [Llm_transport.t] (set via [agent.options.transport])
    handles CLI providers.  Streaming dispatch is likewise consolidated on
    {!Llm_provider.Complete.complete_stream}; no legacy fallback remains. *)
let dispatch_sync = Pipeline_stage_route.dispatch_sync

let dispatch_stream = Pipeline_stage_route.dispatch_stream

(** Dispatch the API call via the chosen strategy (sync or stream). *)
let stage_route
      ~sw
      ?clock
      ~turn
      ~api_strategy
      ?raw_trace_run
      ?on_provider_failure
      ?before_provider_attempt
      ~turn_config
      agent
      prep
  =
  let* provider_config =
    Pipeline_stage_route.provider_config_for_turn ?on_provider_failure ~turn_config agent
  in
  let result =
    match api_strategy with
    | Sync ->
      Tracing.with_span
        agent.options.tracer
        { kind = Api_call
        ; name = "create_message"
        ; agent_name = agent.state.config.name
        ; turn
        ; extra = []
        ; links = []
        }
        (fun tracer ->
           let trace_context = Tracing.trace_context_headers tracer in
           dispatch_sync
             ~sw
             ?clock
             ~trace_context
             ?on_provider_failure
             ?before_provider_attempt
             ~provider_config
             agent
             prep)
    | Stream { on_event; on_telemetry } ->
      let capture_id = Option.map Raw_trace.active_run_id raw_trace_run in
      Tracing.with_span
        agent.options.tracer
        { kind = Api_call
        ; name = "create_message_stream"
        ; agent_name = agent.state.config.name
        ; turn
        ; extra = []
        ; links = []
        }
        (fun tracer ->
           let trace_context = Tracing.trace_context_headers tracer in
           dispatch_stream
             ~sw
             ?clock
             ~provider_config
             ~trace_context
             agent
             prep
             ~on_event
             ?capture_id
             ?on_telemetry
             ?on_provider_failure
             ?before_provider_attempt
             ())
  in
  Result.map (fun response -> provider_config, response) result
;;

(* ── Stage 4: Collect ────────────────────────────────────── *)

(** Accumulate usage, invoke AfterTurn hook, emit events, append
    assistant message, and increment turn_count. *)
let stage_collect ?raw_trace_run ?clock ~turn ~provider_config agent response =
  Tracing.with_span
    agent.options.tracer
    { kind = Hook_invoke
    ; name = "turn:collect"
    ; agent_name = agent.state.config.name
    ; turn
    ; extra = []
    ; links = []
    }
    (fun _tracer ->
       let ts = Pipeline_common.timestamp_now ?clock () in
       (* Preserve an already-recorded first_progress_at (e.g. from streaming
          first-token or tool-execution events). Overwriting it with the
          collection timestamp would make latency-to-first-progress metrics
          silently regress to the end of the turn. *)
       (match agent.lifecycle with
        | Some prev when Option.is_some prev.first_progress_at ->
          set_lifecycle agent ~last_progress_at:ts Running
        | _ -> set_lifecycle agent ~first_progress_at:ts ~last_progress_at:ts Running);
       let* () = trace_assistant_blocks raw_trace_run response.content in
       let usage =
         Agent_turn.accumulate_usage
           ~current_usage:agent.state.usage
           ~provider_config:(Some provider_config)
           ~response_model:(Some response.model)
           ~response_usage:response.usage
       in
       let after_decision =
         invoke_hook_with_trace
           agent
           ?raw_trace_run
           ~turn
           ~hook_name:"after_turn"
           agent.options.hooks.after_turn
           (Hooks.AfterTurn { turn; response })
       in
       let* () =
         match after_decision with
         | Hooks.Continue -> Ok ()
         | Hooks.HookFailed { stage; detail } ->
           Error
             (Pipeline_common.hook_failed_sdk_error
                ~hook_name:"after_turn"
                ~stage
                ~tool_name:None
                ~tool_use_id:None
                ~detail)
         | decision ->
           Error
             (Pipeline_common.illegal_hook_decision_sdk_error
                ~hook_name:"after_turn"
                ~stage:Hooks.After_turn
                ~decision)
       in
       let* assistant_message =
         match Types.assistant_message_of_response response with
         | Ok message -> Ok message
         | Error error ->
           Error
             (Error.Internal
                ("assistant response has invalid reasoning provenance: "
                 ^ Types.show_assistant_message_error error))
       in
       let next_turn = turn + 1 in
       let checkpoint_state =
         { agent.state with
           messages = Util.snoc agent.state.messages assistant_message
         ; turn_count = next_turn
         ; usage
         }
       in
       let* () =
         persist_turn_checkpoint_for_state
           agent
           After_assistant_collected
           checkpoint_state
       in
       update_state agent (fun state ->
         { state with
           messages = Util.snoc state.messages assistant_message
         ; turn_count = next_turn
         ; usage
         });
       (match agent.options.event_bus with
        | Some bus ->
          safe_publish
            bus
            { meta = Pipeline_common.event_envelope agent
            ; payload = TurnCompleted { agent_name = agent.state.config.name; turn }
            }
        | None -> ());
       (* Observability-as-default: emit per-call inference telemetry beside
          [TurnCompleted] so token counts and decode tok/s are observable
          without the caller wiring anything. The event's [provider] is a
          required string, so we publish only once the provider identity is
          known from [response.telemetry.provider_kind] — set by
          [Complete_common.patch_telemetry] on every real completion (sync and
          stream). A synthetic response with no telemetry has no provider to
          attribute and no timings to report, so it is skipped rather than
          emitted with a fabricated provider. Token/timing fields stay [None]
          when the provider did not report them (cloud providers omit timings).
          The nested [None -> ()] arms are explicit (no catch-all) so a future
          telemetry field cannot be silently dropped here. *)
       (match agent.options.event_bus with
        | None -> ()
        | Some bus ->
          (match response.telemetry with
           | None -> ()
           | Some telemetry ->
             (match telemetry.provider_kind with
              | None -> ()
              | Some provider_kind ->
                let timings = telemetry.timings in
                safe_publish
                  bus
                  { meta = Pipeline_common.event_envelope agent
                  ; payload =
                      InferenceTelemetry
                        { agent_name = agent.state.config.name
                        ; turn
                        ; provider = Llm_provider.Provider_kind.to_string provider_kind
                        ; model = response.model
                        ; prompt_tokens =
                            Option.map
                              (fun (u : api_usage) -> u.input_tokens)
                              response.usage
                        ; completion_tokens =
                            Option.map
                              (fun (u : api_usage) -> u.output_tokens)
                              response.usage
                        ; prompt_ms =
                            Option.bind timings (fun (t : inference_timings) ->
                              t.prompt_ms)
                        ; decode_ms =
                            Option.bind timings (fun (t : inference_timings) ->
                              t.predicted_ms)
                        ; decode_tok_s =
                            Option.bind timings (fun (t : inference_timings) ->
                              t.predicted_per_second)
                        }
                  })));
       (match agent.options.journal with
        | Some j ->
          Agent_execution_event_writer.append
            j
            (State_transition
               { from_state = "turn_running"
               ; to_state = "turn_complete"
               ; reason = response.stop_reason |> Types.show_stop_reason
               ; timestamp = Pipeline_common.timestamp_now ?clock ()
               })
        | None -> ());
       Ok ())
;;

(* ── Stage 5: Execute ────────────────────────────────────── *)

(** Handle tool execution and context injection. *)
let stage_execute ?raw_trace_run ?before_tool_execution ~turn ~response agent tools =
  (* [stage_output] rejects empty StopToolUse from provider and injected
     transports. [Nonempty.t] then prevents a silent empty [ToolsExecuted]
     loop at compile time. *)
  let tool_uses = Nonempty.to_list tools in
  Tracing.with_span
    agent.options.tracer
    { kind = Tool_exec
    ; name = "turn:execute"
    ; agent_name = agent.state.config.name
    ; turn
    ; extra = []
    ; links = []
    }
    (fun _tracer ->
       let results, completion, failure =
         execute_tools_with_trace
           agent
           raw_trace_run
           ~turn
           ?before_tool_execution
           tool_uses
         |> Pipeline_terminal_tool.unpack_execution_result
       in
       let tool_results = Agent_turn.make_tool_results results in
       let* () =
         match tool_results with
         | [] -> Ok ()
         | _ ->
           (* Commit completed effects before surfacing a terminal hook or
              observer failure.  Updating memory first prevents same-process
              replay even when the caller-owned checkpoint sink itself fails;
              the checkpoint then makes the same invariant durable. *)
           update_state agent (fun state ->
             { state with
               messages = Util.snoc state.messages (make_message ~role:Tool tool_results)
             });
           let base_state = agent.state in
           persist_turn_checkpoint_for_state agent After_tool_results_appended base_state
       in
       match failure with
       | Some
           (Agent_tools.Hook_failure
              (Agent_tools.Hook_execution_failed
                 { hook_name; stage; tool_name; invocation; detail })) ->
         Error
           (Pipeline_common.hook_failed_sdk_error
              ~hook_name
              ~stage
              ~tool_name:(Some tool_name)
              ~tool_use_id:(Some (Tool_contract.Invocation.tool_use_id invocation))
              ~detail)
       | Some (Agent_tools.Observer_failure { exception_; backtrace; _ }) ->
         Printexc.raise_with_backtrace exception_ backtrace
       | Some (Agent_tools.Durability_failure { invocation; detail }) ->
         Pipeline_terminal_tool.durability_failure ~invocation ~detail
       | None ->
         let finish = Pipeline_terminal_tool.outcome ~response completion in
         (match agent.options.context_injector with
          | None -> finish After_tool_results_appended
          | Some injector ->
            let* messages =
              Agent_turn.apply_context_injection
                ~context:agent.context
                ~messages:agent.state.messages
                ~injector
                ~tool_uses
                ~results
              |> Result.map_error (fun error ->
                Error.Internal
                  (Printf.sprintf
                     "context injector failed%s: %s"
                     (match error.Agent_turn.tool_name with
                      | Some name -> " for tool " ^ name
                      | None -> "")
                     error.detail))
            in
            let injected_state = { agent.state with messages } in
            set_state agent injected_state;
            let* () =
              persist_turn_checkpoint_for_state
                agent
                After_context_injection
                injected_state
            in
            finish After_context_injection))
;;

let replay_settled_before_checkpoint agent =
  Pipeline_terminal_resume.replay
    ~persist_checkpoint:(persist_turn_checkpoint_for_state agent)
    agent
;;

(** Map stop_reason to turn_outcome. *)
let stage_output ?raw_trace_run ?before_tool_execution ~turn agent response =
  Tracing.with_span
    agent.options.tracer
    { kind = Hook_invoke
    ; name = "turn:output"
    ; agent_name = agent.state.config.name
    ; turn
    ; extra = []
    ; links = []
    }
    (fun _tracer ->
       match response.stop_reason with
       | StopToolUse ->
         let tool_uses =
           List.filter
             (fun (block : content_block) ->
                match block with
                | ToolUse _ -> true
                | Text _
                | Thinking _
                | ReasoningDetails _
                | RedactedThinking _
                | ToolResult _
                | Image _
                | Document _
                | Audio _ -> false)
             response.content
         in
         (match Nonempty.of_list tool_uses with
          | None ->
            (* Provider parsers reconcile this shape, but public injected
               transports return [api_response] directly. This driver Gate
               prevents their empty [ToolsExecuted] loop. *)
            Error
              (Error.Agent
                 (UnrecognizedStopReason
                    { reason = "StopToolUse turn carried no tool block" }))
          | Some tool_uses_nonempty ->
            stage_execute
              ?raw_trace_run
              ?before_tool_execution
              ~turn
              ~response
              agent
              tool_uses_nonempty)
       | UnmatchedToolCalls ->
         (* The wire boundary has already classified this response shape as
            malformed. Keep rejecting it; arbitrary provider terminal reasons
            remain fail-closed in their own branch below. *)
         Error
           (Error.Agent
              (UnrecognizedStopReason
                 { reason = Types.stop_reason_to_string response.stop_reason }))
       | EndTurn
       | MaxTokens
       | StopSequence
       | Refusal
       | ContentFilter
       | RepetitionTruncation
       | PauseTurn
       | Compaction
       | ContextWindowExceeded ->
         let stop_decision =
           invoke_hook_with_trace
             agent
             ?raw_trace_run
             ~turn
             ~hook_name:"on_stop"
             agent.options.hooks.on_stop
             (Hooks.OnStop { reason = response.stop_reason; response })
         in
         (match stop_decision with
          | Hooks.Continue -> Ok (Complete response)
          | Hooks.HookFailed { stage; detail } ->
            Error
              (Pipeline_common.hook_failed_sdk_error
                 ~hook_name:"on_stop"
                 ~stage
                 ~tool_name:None
                 ~tool_use_id:None
                 ~detail)
          | ( Hooks.AdjustParams _
            | Hooks.ElicitInput _
            | Hooks.ElicitToolApproval _
            | Hooks.Nudge _
            | Hooks.Block _ ) as decision ->
            Error
              (Pipeline_common.illegal_hook_decision_sdk_error
                 ~hook_name:"on_stop"
                 ~stage:Hooks.On_stop
                 ~decision))
       | Unknown reason -> Error (Error.Agent (UnrecognizedStopReason { reason })))
;;

(* ── Pipeline coordinator ────────────────────────────────── *)

let tag_error stage result =
  match result with
  | Ok _ as ok -> ok
  | Error e ->
    let poly = Error_domain.of_sdk_error e in
    let ctx = Error_domain.with_stage stage poly in
    Log.warn
      _log
      "pipeline stage failed"
      [ Log.S ("stage", stage); Log.S ("error", Error_domain.ctx_to_string ctx) ];
    (* Stage context is observation-only. Return canonical [Error.sdk_error]
       unchanged, including typed fields and provider attribution. *)
    Error e
;;

(* Observation-only domain label for a durable [Error_occurred] event.

   Derived from the actual error via [Error.category] — the exhaustive typed
   SSOT (a new [Error.sdk_error] variant forces a compile error there, so no
   error can silently fall back to a wrong domain). [String.capitalize_ascii]
   only presents the canonical lowercase [category_label] in the durable
   event's historic capitalized style, keeping "Api" for genuine provider
   ([Error.Api]) errors so those logs stay consistent. It is not a classifier:
   classification lives entirely in the typed [Error.category] match. *)
let error_domain_of (err : Error.sdk_error) : string =
  Error.category err |> Error.category_label |> String.capitalize_ascii
;;

let run_new_turn
      ~sw
      ?clock
      ~api_strategy
      ?raw_trace_run
      ?on_provider_failure
      ?before_tool_execution
      agent
  =
  (* One immutable zero-based identity owns the complete provider turn.  The
     collect stage advances mutable agent state before output/tool dispatch,
     so reading [state.turn_count] again downstream would name the next turn. *)
  let turn = agent.state.turn_count in
  (* Stage 1: Input *)
  let* () =
    Tracing.with_span
      agent.options.tracer
      { kind = Hook_invoke
      ; name = "turn:input"
      ; agent_name = agent.state.config.name
      ; turn
      ; extra = []
      ; links = []
      }
      (fun _tracer -> stage_input ?raw_trace_run ?clock ~turn agent |> tag_error "input")
  in
  (* Stage 2: Parse *)
  let* prep, turn_config, turn_params =
    Tracing.with_span
      agent.options.tracer
      { kind = Hook_invoke
      ; name = "turn:parse"
      ; agent_name = agent.state.config.name
      ; turn
      ; extra = []
      ; links = []
      }
      (fun _tracer -> stage_parse ?raw_trace_run ?clock ~turn agent |> tag_error "parse")
  in
  (* Stage 2.5: Async input validation *)
  let async_guard = agent.options.guardrails_async in
  match
    Guardrails_async.run_input
      async_guard.input_validators
      prep.Agent_turn.effective_messages
  with
  | Guardrails_async.Fail { validator_name; reason } ->
    Error (Error.Agent (GuardrailViolation { validator = validator_name; reason }))
  | Guardrails_async.Pass ->
    let* execution =
      Pipeline_execution_scope.open_turn (Execution_context.agent_scope ()) ~ordinal:turn
    in
    (* Stage 3: Route exactly once. Provider [ContextOverflow] remains a typed
       error; OAS does not mutate the transcript or retry implicitly. *)
    (match agent.options.journal with
     | Some j ->
       Agent_execution_event_writer.append
         j
         (Llm_request
            { turn
            ; model = turn_config.model
            ; timestamp = Pipeline_common.timestamp_now ?clock ()
            })
     | None -> ());
    let t0 = Pipeline_common.timestamp_now ?clock () in
    let api_result =
      stage_route
        ~sw
        ?clock
        ~turn
        ~api_strategy
        ?raw_trace_run
        ?on_provider_failure
        ~before_provider_attempt:
          (Pipeline_execution_scope.before_provider_attempt execution)
        ~turn_config
        agent
        prep
      |> tag_error "route"
    in
    let duration_ms = (Pipeline_common.timestamp_now ?clock () -. t0) *. 1000.0 in
    (match agent.options.journal, api_result with
     | Some j, Ok (_, response) ->
       let input_tokens, output_tokens =
         match response.usage with
         | Some u -> Some u.input_tokens, Some u.output_tokens
         | None -> None, None
       in
       Agent_execution_event_writer.append
         j
         (Llm_response
            { turn
            ; input_tokens
            ; output_tokens
            ; stop_reason = Types.show_stop_reason response.stop_reason
            ; duration_ms
            ; timestamp = Pipeline_common.timestamp_now ?clock ()
            })
     | Some j, Error err ->
       Agent_execution_event_writer.append
         j
         (Error_occurred
            { turn
            ; error_domain = error_domain_of err
            ; detail = Error.to_string err
            ; timestamp = Pipeline_common.timestamp_now ?clock ()
            })
     | None, _ -> ());
    (* Stage 4+5+6: Collect, Execute/Output *)
    let outcome =
      match api_result with
      | Error e -> Error e
      | Ok (provider_config, response) ->
        (* RFC-OAS-025 Option A: forced-tool-use enforcement removed.
          [tool_choice] is enforced server-side by the provider, so the SDK no
          longer validates the response against a completion contract nor retries
          to coerce a tool call (the former
          [handle_missing_required_tool_use]/[validate_completion_contract]
          pass). *)
        (* Stage 3.5: Async output validation *)
        (match Guardrails_async.run_output async_guard.output_validators response with
         | Guardrails_async.Fail { validator_name; reason } ->
           Error (Error.Agent (GuardrailViolation { validator = validator_name; reason }))
         | Guardrails_async.Pass ->
           let* () =
             Pipeline_execution_scope.record_provider_response execution response
             |> tag_error "response"
           in
           let* () =
             stage_collect ?raw_trace_run ?clock ~turn ~provider_config agent response
             |> tag_error "collect"
           in
           (match Pipeline_execution_scope.provider execution with
            | None ->
              stage_output ?raw_trace_run ?before_tool_execution ~turn agent response
            | Some provider ->
              Execution_context.with_provider_attempt provider (fun () ->
                stage_output ?raw_trace_run ?before_tool_execution ~turn agent response))
           |> tag_error "output")
    in
    (match outcome with
     | Error _ as error -> error
     | Ok value ->
       Pipeline_execution_scope.close_success execution |> Result.map (fun () -> value))
;;

(* Resume-vs-fresh dispatch (including settled-boundary replay and terminal
   reconstruction) lives in [Pipeline_execution_resume]; this driver supplies the
   fresh-turn continuation and the turn_outcome constructors as pure values, so
   the resume flag is consumed inside [dispatch] in the same order as before. *)
let run_turn
      ~sw
      ?clock
      ~api_strategy
      ?raw_trace_run
      ?on_provider_failure
      ?before_tool_execution
      agent
  =
  Pipeline_execution_resume.dispatch
    agent
    (* Thread [before_tool_execution] (the provider-lease [on_yield] release) as
         the fresh path threads it below; dropping it disabled [yield_on_tool]'s
         release on the resume turn (lease advanced but never released). The turn
         identity is the durable turn ordinal supplied by [dispatch]
         ([turn_ordinal]), not [agent.state.turn_count], so the resumed turn is
         traced under the exact ordinal the crashed run used (#2709). *)
    ~execute:(fun ~turn ~response tool_uses ->
      stage_execute ?raw_trace_run ?before_tool_execution ~turn ~response agent tool_uses)
    ~all_pre_tool_use_blocked:(ToolsExecuted After_tool_results_appended)
    ~tools_settled_before_checkpoint:(replay_settled_before_checkpoint agent)
    ~tools_settled:Pipeline_terminal_tool.recovered_outcome
    ~terminal:(fun response -> Complete response)
    ~fresh:(fun () ->
      run_new_turn
        ~sw
        ?clock
        ~api_strategy
        ?raw_trace_run
        ?on_provider_failure
        ?before_tool_execution
        agent)
;;

[@@@coverage off]
(* === Inline tests === *)

let%test "last_tool_results_from empty messages" = last_tool_results_from [] = []

let%test "last_tool_results_from no tool results" =
  let msgs =
    [ { role = User
      ; content = [ Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  last_tool_results_from msgs = []
;;

let%test "last_tool_results_from finds tool results in last tool message" =
  let msgs =
    [ { role = Assistant
      ; content = [ Text "thinking..." ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Tool
      ; content =
          [ ToolResult
              { tool_use_id = "t1"
              ; content = "result1"
              ; outcome = Tool_succeeded
              ; json = None
              ; content_blocks = None
              }
          ; ToolResult
              { tool_use_id = "t2"
              ; content = "error msg"
              ; outcome =
                  Tool_failed { failure_kind = Reported_tool_error; error_class = None }
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  match last_tool_results_from msgs with
  | [ Ok { content = "result1"; _meta = _ }
    ; Error { message = "error msg"; recoverable = false; error_class = None }
    ] -> true
  | _ -> false
;;

let%test "last_tool_results_from ignores tool results outside tool role" =
  let msgs =
    [ { role = User
      ; content =
          [ ToolResult
              { tool_use_id = "t1"
              ; content = "first"
              ; outcome = Tool_succeeded
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Assistant
      ; content = [ Text "response" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = User
      ; content = [ Text "follow up" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  last_tool_results_from msgs = []
;;

let%test "tag_error passes through Ok" =
  let result = tag_error "test_stage" (Ok 42) in
  result = Ok 42
;;

let%test "tag_error passes through Error" =
  let err = Error.Internal "test error" in
  match tag_error "test_stage" (Error err) with
  | Error e -> e = err
  | Ok _ -> false
;;

(* --- Additional coverage tests --- *)

let%test "last_tool_results_from assistant-only messages" =
  let msgs =
    [ { role = Assistant
      ; content = [ Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Assistant
      ; content = [ Text "world" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  last_tool_results_from msgs = []
;;

let%test "last_tool_results_from picks last tool-result message" =
  let msgs =
    [ { role = Tool
      ; content =
          [ ToolResult
              { tool_use_id = "t1"
              ; content = "first"
              ; outcome = Tool_succeeded
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Assistant
      ; content = [ Text "mid" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Tool
      ; content =
          [ ToolResult
              { tool_use_id = "t2"
              ; content = "second"
              ; outcome = Tool_succeeded
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  match last_tool_results_from msgs with
  | [ Ok { content = "second"; _meta = _ } ] -> true
  | _ -> false
;;

let%test "last_tool_results_from ignores mixed content outside tool role" =
  let msgs =
    [ { role = User
      ; content =
          [ Text "some text"
          ; ToolResult
              { tool_use_id = "t1"
              ; content = "ok"
              ; outcome = Tool_succeeded
              ; json = None
              ; content_blocks = None
              }
          ; Text "more text"
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  last_tool_results_from msgs = []
;;

let%test "last_tool_results_from error tool result" =
  let msgs =
    [ { role = Tool
      ; content =
          [ ToolResult
              { tool_use_id = "t1"
              ; content = "fail msg"
              ; outcome =
                  Tool_failed { failure_kind = Reported_tool_error; error_class = None }
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  match last_tool_results_from msgs with
  | [ Error { message = "fail msg"; recoverable = false; error_class = None } ] -> true
  | _ -> false
;;

(* --- Additional pipeline tests --- *)

let%test "last_tool_results_from only non-result roles" =
  let msgs =
    [ { role = System
      ; content = [ Text "system" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Assistant
      ; content = [ Text "reply" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  last_tool_results_from msgs = []
;;

let%test "last_tool_results_from multiple tool results in one message" =
  let msgs =
    [ { role = Tool
      ; content =
          [ ToolResult
              { tool_use_id = "t1"
              ; content = "r1"
              ; outcome = Tool_succeeded
              ; json = None
              ; content_blocks = None
              }
          ; ToolResult
              { tool_use_id = "t2"
              ; content = "r2"
              ; outcome = Tool_succeeded
              ; json = None
              ; content_blocks = None
              }
          ; ToolResult
              { tool_use_id = "t3"
              ; content = "r3"
              ; outcome =
                  Tool_failed { failure_kind = Reported_tool_error; error_class = None }
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  List.length (last_tool_results_from msgs) = 3
;;

let%test "last_tool_results_from user msg with only non-tool content" =
  let msgs =
    [ { role = User
      ; content =
          [ Text "just text"; Types.ToolUse { id = "tu1"; name = "fn"; input = `Null } ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  last_tool_results_from msgs = []
;;
