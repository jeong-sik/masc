(** Agent implementation using Eio structured concurrency.

    Supports hooks, context, and content validators as optional features.

    Lifecycle logic lives in {!Agent_lifecycle}, checkpoint logic in
    {!Agent_checkpoint}.  Sync and streaming turns share a single
    {!run_turn_core} with an [api_strategy] parameter. *)

module Retry = Llm_provider.Retry
open Types
include Agent_types
open Agent_trace
open Agent_run_loop_support

let _log = Log.create ~module_name:"agent" ()

(* ── Unified turn execution (delegated to Pipeline) ──────────── *)

type api_strategy = Pipeline.api_strategy =
  | Sync
  | Stream of
      { on_event : Types.sse_event -> unit
      ; on_telemetry : (Llm_provider.Telemetry_event.t -> unit) option
      }

type detailed_error = Provider_failure_attribution.detailed_error =
  { error : Error.sdk_error
  ; provider_failure : Provider_failure_attribution.t option
  }

let detailed_error_of_sdk_error = Provider_failure_attribution.of_sdk_error

type execution_runtime = Agent_execution_runner.runtime
type execution_store = Agent_execution_runner.store
type execution_locator = Agent_execution_runner.locator

type execution_terminal_outcome = Agent_execution_runner.terminal_outcome =
  | Terminal_succeeded
  | Terminal_failed
  | Terminal_cancelled

type execution_operator_repair_reason = Agent_execution_runner.operator_repair_reason =
  | Effect_outcome_unknown

type execution_recovery_action = Agent_execution_runner.recovery_action =
  | Retire
  | Operator_repair_required of execution_operator_repair_reason

type execution_terminal_disposition = Agent_execution_runner.terminal_disposition =
  { outcome : execution_terminal_outcome
  ; recovery : execution_recovery_action
  }

module Execution_projection = Agent_execution_projection

let create_execution_runtime = Agent_execution_runner.create_runtime
let execution_store = Agent_execution_runner.store
let execution_locator_to_yojson = Agent_execution_runner.locator_to_yojson
let execution_locator_of_yojson = Agent_execution_runner.locator_of_yojson

let open_execution_projection ~runtime ~dir locator =
  Execution_projection.open_durable
    ~codec:(Agent_execution_runner.runtime_codec runtime)
    ~dir
    ~locator_run_id:(Agent_execution_runner.locator_run_id locator)
    ()
;;

let replace_projected_error error detailed =
  { detailed with Provider_failure_attribution.error }
;;

let project_detailed_error result =
  Result.map_error (fun detailed -> detailed.error) result
;;

(** Run a single turn via the 6-stage pipeline, converting [Pipeline.turn_outcome]
    to the polymorphic variant interface expected by [run_loop] and the public API. *)
let run_turn_core_detailed
      ~sw
      ?clock
      ~api_strategy
      ?raw_trace_run
      ?before_tool_execution
      agent
  =
  let provider_failure = ref None in
  Tracing.with_span
    agent.options.tracer
    { kind = Agent_run
    ; name = "agent_turn"
    ; agent_name = agent.state.config.name
    ; turn = agent.state.turn_count
    ; extra = []
    ; links =
        (match agent.options.trace_link with
         | Some (tid, sid) -> [ tid, sid ]
         | None -> [])
    }
    (fun _tracer ->
       let api_strat =
         match api_strategy with
         | Sync -> Pipeline.Sync
         | Stream { on_event; on_telemetry } -> Pipeline.Stream { on_event; on_telemetry }
       in
       match
         Pipeline.run_turn
           ~sw
           ?clock
           ~api_strategy:api_strat
           ?raw_trace_run
           ?before_tool_execution
           ~on_provider_failure:(fun attribution -> provider_failure := attribution)
           agent
       with
       | Ok (Pipeline.Complete response) -> Ok (`Complete response)
       | Ok (Pipeline.ToolsExecuted checkpoint_stage) ->
         Ok (`ToolsExecuted checkpoint_stage)
       | Ok (Pipeline.TerminalToolCompleted completion) ->
         Ok (`TerminalToolCompleted completion)
       | Error error -> Error { error; provider_failure = !provider_failure })
;;

let run_turn_core ~sw ?clock ~api_strategy ?raw_trace_run agent =
  run_turn_core_detailed ~sw ?clock ~api_strategy ?raw_trace_run agent
  |> project_detailed_error
;;

(* Original run_turn_core implementation removed — now in Pipeline.run_turn.
   See git history for the previous 240-line monolithic version. *)

let provide_input agent request response =
  if Agent_elicitation.apply_response ~metadata:[] agent request response then ()
;;

(* ── Unified run loop ────────────────────────────────────────── *)

let base_messages = Agent_input.base_messages
let trace_prompt_of_blocks = Agent_input.trace_prompt_of_blocks
let validate_user_input_blocks = Agent_input.validate_user_input_blocks
let append_user_input = Agent_input.append_user_input
let resume_user_input = Agent_input.resume_user_input

(** Per-turn timing observability helper. Emits one structured record
    per turn so operators diagnosing wall-clock timeouts can see
    whether time was spent on many moderate turns or a single
    slow one.  Goes through {!Log.info} rather than [Printf.eprintf]
    so [ppx_inline_test] does not capture the line as an unexpected
    stderr diff (raw eprintf during tests makes CI fail even when every
    test asserts green; see #799).  When no sink is registered the
    enabled emit attempt is counted by {!Log.dropped_without_sink_count}
    and dropped without allocating a record, so hosts can detect missing
    telemetry wiring without forcing stderr output. Disabled records below
    the global log level are filtered before this counter is considered. *)
let run_loop_turns_detailed
      ~sw
      ?clock
      ~api_strategy
      ?on_yield
      ?on_resume
      ?raw_trace_run
      agent
  =
  let yield_enabled = agent.state.config.yield_on_tool in
  let run_start = Unix.gettimeofday () in
  let rec loop lease =
    let lease = acquire_provider_lease ~yield_enabled ~on_resume lease in
    let release = plan_provider_lease_release ~yield_enabled ~on_yield lease in
    let turn_index = agent.state.turn_count + 1 in
    let turn_start = Unix.gettimeofday () in
    let result =
      run_turn_core_detailed
        ~sw
        ?clock
        ~api_strategy
        ?raw_trace_run
        ?before_tool_execution:release.before_tool_execution
        agent
    in
    match result with
    | Error e ->
      log_turn
        ~run_start
        ~turn_start
        ~turn_index
        ~model:agent.state.config.model
        ~stop:("error:" ^ Error.to_string e.error);
      Error e
    | Ok (`Complete response) ->
      log_turn
        ~run_start
        ~turn_start
        ~turn_index
        ~model:response.model
        ~stop:(stop_reason_label response.stop_reason);
      Ok response
    | Ok (`ToolsExecuted _) ->
      log_turn
        ~run_start
        ~turn_start
        ~turn_index
        ~model:agent.state.config.model
        ~stop:"tools_executed";
      loop (release.after ())
    | Ok (`TerminalToolCompleted completion) ->
      log_turn
        ~run_start
        ~turn_start
        ~turn_index
        ~model:completion.response.model
        ~stop:"terminal_tool_completed";
      Ok completion.response
  in
  loop Held
;;

let ambient_execution_scope_factory agent =
  Execution_context.child_scope_factory ()
  |> Option.map (fun start_child () -> start_child ~agent_name:agent.state.config.name)
;;

let run_with_execution_scope ~sw ?execution_store agent run =
  let execution_scope_factory = ambient_execution_scope_factory agent in
  match execution_store, execution_scope_factory with
  | None, None -> run ~sw
  | Some store, None ->
    Agent_execution_runner.with_store store agent (fun ~sw _execution_scope -> run ~sw)
  | None, Some start_scope ->
    (match start_scope () with
     | Error error ->
       Error
         (detailed_error_of_sdk_error
            (Error.Internal
               ("durable child scope: " ^ Execution_agent_scope.error_to_string error)))
     | Ok execution_scope ->
       Agent_execution_runner.with_scope execution_scope (fun () -> run ~sw))
  | Some _, Some _ ->
    Error
      (detailed_error_of_sdk_error
         (Error.Internal "execution store and child scope factory are mutually exclusive"))
;;

let run_loop_detailed
      ~sw
      ?clock
      ~api_strategy
      ?on_yield
      ?on_resume
      ?execution_store
      agent
      user_blocks
  =
  let open Result_syntax in
  let resuming =
    match execution_store with
    | Some store -> Agent_execution_runner.is_resume store
    | None -> false
  in
  let* user_blocks =
    if resuming
    then
      resume_user_input agent user_blocks |> Result.map_error detailed_error_of_sdk_error
    else Ok (append_user_input agent user_blocks)
  in
  let trace_prompt = trace_prompt_of_blocks user_blocks in
  with_raw_trace_run_result
    ~of_sdk_error:detailed_error_of_sdk_error
    ~error_to_string:(fun detailed -> Error.to_string detailed.error)
    agent
    trace_prompt
  @@ fun raw_trace_run ->
  let run ~sw =
    run_loop_turns_detailed
      ~sw
      ?clock
      ~api_strategy
      ?on_yield
      ?on_resume
      ?raw_trace_run
      agent
  in
  run_with_execution_scope ~sw ?execution_store agent run
;;

let run_loop
      ~sw
      ?clock
      ~api_strategy
      ?on_yield
      ?on_resume
      ?execution_store
      agent
      user_blocks
  =
  run_loop_detailed
    ~sw
    ?clock
    ~api_strategy
    ?on_yield
    ?on_resume
    ?execution_store
    agent
    user_blocks
  |> project_detailed_error
;;

(* Start periodic callback fibers, return a stop function *)
let start_periodic_callbacks ~sw ?clock (cbs : periodic_callback list) =
  match clock with
  | None -> fun () -> ()
  | Some clock ->
    let stops =
      List.map
        (fun cb ->
           let active = ref true in
           Eio.Fiber.fork ~sw (fun () ->
             let rec tick () =
               if !active
               then (
                 Eio.Time.sleep clock cb.interval_sec;
                 if !active
                 then (
                   try cb.callback () with
                   | (Eio.Cancel.Cancelled _ | Out_of_memory | Stack_overflow | Sys.Break)
                     as ex -> raise ex
                   | exn ->
                     Log.warn
                       _log
                       "periodic callback raised"
                       [ Log.S ("error", Printexc.to_string exn) ]);
                 tick ())
             in
             try tick () with
             | (Eio.Cancel.Cancelled _ | Out_of_memory | Stack_overflow | Sys.Break) as ex
               -> raise ex
             | exn ->
               Log.warn
                 _log
                 "periodic tick crashed"
                 [ Log.S ("error", Printexc.to_string exn) ]);
           fun () -> active := false)
        cbs
    in
    fun () -> List.iter (fun stop -> stop ()) stops
;;

let stop_once stop =
  let stopped = Atomic.make false in
  fun () -> if Atomic.compare_and_set stopped false true then stop ()
;;

let with_periodic_callbacks ~sw ?clock agent f =
  match agent.options.periodic_callbacks with
  | [] -> f ~sw
  | callbacks ->
    Eio.Switch.run
    @@ fun callback_sw ->
    let stop = start_periodic_callbacks ~sw:callback_sw ?clock callbacks |> stop_once in
    (match f ~sw with
     | result ->
       stop ();
       result
     | exception exn ->
       stop ();
       raise exn)
;;

let with_run_lifecycle_events agent f =
  Agent_lifecycle_events.with_run_lifecycle_events
    ~event_bus:agent.options.event_bus
    ~agent_name:agent.state.config.name
    ~raw_trace:agent.options.raw_trace
    ~current_run_id:(fun () ->
      Option.bind (lifecycle_snapshot agent) (fun s -> s.current_run_id))
    ~project:(fun detailed -> detailed.Provider_failure_attribution.error)
    f
;;

let run_blocks_detailed ~sw ?clock ?on_yield ?on_resume ?execution_store agent user_blocks
  =
  with_run_lifecycle_events agent (fun () ->
    match validate_user_input_blocks user_blocks with
    | Error error -> Error (detailed_error_of_sdk_error error)
    | Ok () ->
      (match Agent_lifecycle_events.validate_run_callbacks ~on_yield ~on_resume with
       | Error error -> Error (detailed_error_of_sdk_error error)
       | Ok () ->
         with_periodic_callbacks ~sw ?clock agent (fun ~sw ->
           run_loop_detailed
             ~sw
             ?clock
             ~api_strategy:Sync
             ?on_yield
             ?on_resume
             ?execution_store
             agent
             user_blocks)))
;;

let run_blocks ~sw ?clock ?on_yield ?on_resume ?execution_store agent user_blocks =
  run_blocks_detailed ~sw ?clock ?on_yield ?on_resume ?execution_store agent user_blocks
  |> project_detailed_error
;;

let run_detailed ~sw ?clock ?on_yield ?on_resume ?execution_store agent user_prompt =
  run_blocks_detailed
    ~sw
    ?clock
    ?on_yield
    ?on_resume
    ?execution_store
    agent
    [ Text user_prompt ]
;;

let run ~sw ?clock ?on_yield ?on_resume ?execution_store agent user_prompt =
  run_detailed ~sw ?clock ?on_yield ?on_resume ?execution_store agent user_prompt
  |> project_detailed_error
;;

let run_stream_blocks_detailed
      ~sw
      ?clock
      ~on_event
      ?on_yield
      ?on_resume
      ?execution_store
      agent
      user_blocks
  =
  with_run_lifecycle_events agent (fun () ->
    match validate_user_input_blocks user_blocks with
    | Error error -> Error (detailed_error_of_sdk_error error)
    | Ok () ->
      (match Agent_lifecycle_events.validate_run_callbacks ~on_yield ~on_resume with
       | Error error -> Error (detailed_error_of_sdk_error error)
       | Ok () ->
         let on_telemetry =
           Option.map
             (fun bus -> Telemetry_bus.publish (Telemetry_bus.of_event_bus bus))
             agent.options.event_bus
         in
         with_periodic_callbacks ~sw ?clock agent (fun ~sw ->
           run_loop_detailed
             ~sw
             ?clock
             ~api_strategy:(Stream { on_event; on_telemetry })
             ?on_yield
             ?on_resume
             ?execution_store
             agent
             user_blocks)))
;;

let run_stream_blocks
      ~sw
      ?clock
      ~on_event
      ?on_yield
      ?on_resume
      ?execution_store
      agent
      user_blocks
  =
  run_stream_blocks_detailed
    ~sw
    ?clock
    ~on_event
    ?on_yield
    ?on_resume
    ?execution_store
    agent
    user_blocks
  |> project_detailed_error
;;

let run_stream_detailed
      ~sw
      ?clock
      ~on_event
      ?on_yield
      ?on_resume
      ?execution_store
      agent
      user_prompt
  =
  run_stream_blocks_detailed
    ~sw
    ?clock
    ~on_event
    ?on_yield
    ?on_resume
    ?execution_store
    agent
    [ Text user_prompt ]
;;

let run_stream
      ~sw
      ?clock
      ~on_event
      ?on_yield
      ?on_resume
      ?execution_store
      agent
      user_prompt
  =
  run_stream_detailed
    ~sw
    ?clock
    ~on_event
    ?on_yield
    ?on_resume
    ?execution_store
    agent
    user_prompt
  |> project_detailed_error
;;

let validate_handoff_targets agent (targets : Handoff.handoff_target list) =
  let rec loop seen (remaining : Handoff.handoff_target list) =
    match remaining with
    | [] -> Ok ()
    | (target : Handoff.handoff_target) :: rest ->
      if target.name = ""
      then
        Error
          (Error.Config
             (Error.InvalidConfig
                { field = "handoff targets"; detail = "target name must not be empty" }))
      else if List.mem target.name seen
      then
        Error
          (Error.Config
             (Error.InvalidConfig
                { field = "handoff targets"
                ; detail = Printf.sprintf "duplicate target name: %s" target.name
                }))
      else if Tool_set.mem target.name agent.tools
      then
        Error
          (Error.Config
             (Error.InvalidConfig
                { field = "handoff targets"
                ; detail =
                    Printf.sprintf
                      "target name conflicts with an existing tool: %s"
                      target.name
                }))
      else loop (target.name :: seen) rest
  in
  loop [] targets
;;

let publish_handoff_requested agent (target : Handoff.handoff_target) prompt =
  match agent.options.event_bus with
  | None -> None
  | Some bus ->
    let run_id = Event_bus.fresh_id () in
    (try
       Event_bus.publish
         bus
         (Event_bus.mk_event
            ~run_id
            (HandoffRequested
               { from_agent = agent.state.config.name
               ; to_agent = target.name
               ; reason = prompt
               }))
     with
     | exn ->
       Llm_provider.Reserved_exn.reraise_if_reserved exn;
       Log.warn
         _log
         "Event_bus.publish failed (HandoffRequested)"
         [ Log.S ("error", Printexc.to_string exn) ]);
    Some run_id
;;

let publish_handoff_completed agent (target : Handoff.handoff_target) ~caused_by ~elapsed =
  match agent.options.event_bus with
  | None -> ()
  | Some bus ->
    (try
       Event_bus.publish
         bus
         (Event_bus.mk_event
            ?caused_by
            (HandoffCompleted
               { from_agent = agent.state.config.name; to_agent = target.name; elapsed }))
     with
     | exn ->
       Llm_provider.Reserved_exn.reraise_if_reserved exn;
       Log.warn
         _log
         "Event_bus.publish failed (HandoffCompleted)"
         [ Log.S ("error", Printexc.to_string exn) ])
;;

let run_handoff_target ~sw ?clock agent (target : Handoff.handoff_target) prompt =
  let caused_by = publish_handoff_requested agent target prompt in
  let started_at = Unix.gettimeofday () in
  let sub =
    create
      ~net:agent.net
      ~config:target.config
      ~tools:target.tools
      ~context_fit_admission:agent.context_fit_admission
      ?model_input_projection:agent.model_input_projection
      ?pre_dispatch_serialization_observer:agent.pre_dispatch_serialization_observer
      ~options:
        { default_options with
          transport = agent.options.transport
        ; provider_config = agent.options.provider_config
        }
      ()
  in
  let result = run ~sw ?clock sub prompt in
  publish_handoff_completed
    agent
    target
    ~caused_by
    ~elapsed:(Unix.gettimeofday () -. started_at);
  match result with
  | Ok response ->
    Ok { Types.content = Types.visible_text_of_response response; _meta = None }
  | Error error ->
    Error
      { message =
          Printf.sprintf "Handoff to %s failed: %s" target.name (Error.to_string error)
      ; recoverable = false
      ; error_class = Some Unknown
      }
;;

let run_with_handoffs_blocks_detailed
      ~sw
      ?clock
      ?execution_store
      agent
      ~targets
      user_blocks
  =
  match validate_user_input_blocks user_blocks with
  | Error error -> Error (detailed_error_of_sdk_error error)
  | Ok () ->
    (match validate_handoff_targets agent targets with
     | Error error -> Error (detailed_error_of_sdk_error error)
     | Ok () ->
       let handoff_tools =
         List.map
           (fun target ->
              Handoff.make_handoff_tool
                ~delegate:(run_handoff_target ~sw ?clock agent target)
                target)
           targets
       in
       let all_tools = Tool_set.merge agent.tools (Tool_set.of_list handoff_tools) in
       let agent_with_handoffs = { agent with tools = all_tools } in
       run_blocks_detailed ~sw ?clock ?execution_store agent_with_handoffs user_blocks)
;;

let run_with_handoffs_detailed ~sw ?clock ?execution_store agent ~targets user_prompt =
  run_with_handoffs_blocks_detailed
    ~sw
    ?clock
    ?execution_store
    agent
    ~targets
    [ Text user_prompt ]
;;

let run_with_handoffs ~sw ?clock ?execution_store agent ~targets user_prompt =
  run_with_handoffs_detailed ~sw ?clock ?execution_store agent ~targets user_prompt
  |> project_detailed_error
;;

let run_with_handoffs_blocks ~sw ?clock ?execution_store agent ~targets user_blocks =
  run_with_handoffs_blocks_detailed ~sw ?clock ?execution_store agent ~targets user_blocks
  |> project_detailed_error
;;

let resume
      ~net
      ~(checkpoint : Checkpoint.t)
      ?(tools = [])
      ?context
      ?(options = default_options)
      ?(context_fit_admission = Disabled)
      ?model_input_projection
      ?pre_dispatch_serialization_observer
      ?checkpoint_sink
      ?config
      ()
  =
  let { Agent_checkpoint.state; context = ctx } =
    Agent_checkpoint.build_resume ~checkpoint ~eio_context:true ?config ?context ()
  in
  { mu = Eio.Mutex.create ()
  ; state
  ; lifecycle = None
  ; tools = Tool_set.of_list tools
  ; net
  ; context = ctx
  ; options
  ; context_fit_admission
  ; model_input_projection
  ; pre_dispatch_serialization_observer
  ; checkpoint_sink
  }
;;

let checkpoint ?(session_id = "") ?working_context agent =
  Agent_checkpoint.build_checkpoint
    ~session_id
    ?working_context
    ~state:agent.state
    ~tools:agent.tools
    ~context:agent.context
    ~mcp_clients:agent.options.mcp_clients
    ()
;;

module Advanced = struct
  type tool_boundary =
    { turn : int
    ; checkpoint_stage : checkpoint_stage
    }

  type boundary_decision =
    | Continue
    | Yield

  type yielded =
    { turn : int
    ; checkpoint_stage : checkpoint_stage
    ; checkpoint : Checkpoint.t
    }

  type terminal_tool_completed =
    { turn : int
    ; receipt : Terminal_tool_receipt.t
    ; checkpoint : Checkpoint.t
    }

  type run_outcome =
    | Completed of Types.api_response
    | Yielded of yielded
    | Terminal_tool_completed of terminal_tool_completed

  let raw_trace_yield_stop_reason = "cooperative_tool_boundary_yield"

  let completed_tool_boundary agent checkpoint_stage =
    { turn = agent.state.turn_count; checkpoint_stage }
  ;;

  let classify_trace_success = function
    | Completed response ->
      Run_completed
        { final_text = final_text_of_response response
        ; stop_reason = Some (Types.show_stop_reason response.stop_reason)
        }
    | Yielded _ -> Run_yielded { stop_reason = raw_trace_yield_stop_reason }
    | Terminal_tool_completed completion ->
      Run_completed
        { final_text = final_text_of_response completion.receipt.response
        ; stop_reason = Some "terminal_tool_completed"
        }
  ;;

  let run_loop_turns_detailed
        ~sw
        ?clock
        ~api_strategy
        ?on_yield
        ?on_resume
        ?raw_trace_run
        ~on_tool_boundary
        agent
    =
    let yield_enabled = agent.state.config.yield_on_tool in
    let run_start = Unix.gettimeofday () in
    let rec loop lease =
      let lease = acquire_provider_lease ~yield_enabled ~on_resume lease in
      let release = plan_provider_lease_release ~yield_enabled ~on_yield lease in
      let turn_index = agent.state.turn_count + 1 in
      let turn_start = Unix.gettimeofday () in
      match
        run_turn_core_detailed
          ~sw
          ?clock
          ~api_strategy
          ?raw_trace_run
          ?before_tool_execution:release.before_tool_execution
          agent
      with
      | Error error ->
        log_turn
          ~run_start
          ~turn_start
          ~turn_index
          ~model:agent.state.config.model
          ~stop:("error:" ^ Error.to_string error.error);
        Error error
      | Ok (`Complete response) ->
        log_turn
          ~run_start
          ~turn_start
          ~turn_index
          ~model:response.model
          ~stop:(stop_reason_label response.stop_reason);
        Ok (Completed response)
      | Ok (`ToolsExecuted checkpoint_stage) ->
        log_turn
          ~run_start
          ~turn_start
          ~turn_index
          ~model:agent.state.config.model
          ~stop:"tools_executed";
        let boundary = completed_tool_boundary agent checkpoint_stage in
        (match on_tool_boundary boundary with
         | Continue -> loop (release.after ())
         | Yield ->
           let checkpoint = checkpoint agent in
           Ok
             (Yielded
                { turn = boundary.turn
                ; checkpoint_stage = boundary.checkpoint_stage
                ; checkpoint
                }))
      | Ok (`TerminalToolCompleted receipt) ->
        log_turn
          ~run_start
          ~turn_start
          ~turn_index
          ~model:receipt.response.model
          ~stop:"terminal_tool_completed";
        Ok
          (Terminal_tool_completed
             { turn = agent.state.turn_count; receipt; checkpoint = checkpoint agent })
    in
    loop Held
  ;;

  let run_loop_detailed
        ~sw
        ?clock
        ~api_strategy
        ?on_yield
        ?on_resume
        ?execution_store
        ~on_tool_boundary
        agent
        user_blocks
    =
    let open Result_syntax in
    let resuming =
      match execution_store with
      | Some store -> Agent_execution_runner.is_resume store
      | None -> false
    in
    let* user_blocks =
      if resuming
      then
        resume_user_input agent user_blocks
        |> Result.map_error detailed_error_of_sdk_error
      else Ok (append_user_input agent user_blocks)
    in
    let trace_prompt = trace_prompt_of_blocks user_blocks in
    with_raw_trace_run_classified_result
      ~of_sdk_error:detailed_error_of_sdk_error
      ~error_to_string:(fun detailed -> Error.to_string detailed.error)
      ~classify_success:classify_trace_success
      agent
      trace_prompt
    @@ fun raw_trace_run ->
    let run ~sw =
      run_loop_turns_detailed
        ~sw
        ?clock
        ~api_strategy
        ?on_yield
        ?on_resume
        ?raw_trace_run
        ~on_tool_boundary
        agent
    in
    run_with_execution_scope ~sw ?execution_store agent run
  ;;

  let run_blocks_detailed
        ~sw
        ?clock
        ?on_yield
        ?on_resume
        ?execution_store
        ~api_strategy
        ~on_tool_boundary
        agent
        user_blocks
    =
    match validate_user_input_blocks user_blocks with
    | Error error -> Error (detailed_error_of_sdk_error error)
    | Ok () ->
      (match Agent_lifecycle_events.validate_run_callbacks ~on_yield ~on_resume with
       | Error error -> Error (detailed_error_of_sdk_error error)
       | Ok () ->
         with_periodic_callbacks ~sw ?clock agent (fun ~sw ->
           run_loop_detailed
             ~sw
             ?clock
             ~api_strategy
             ?on_yield
             ?on_resume
             ?execution_store
             ~on_tool_boundary
             agent
             user_blocks))
  ;;

  let run_blocks
        ~sw
        ?clock
        ?on_yield
        ?on_resume
        ?execution_store
        ~api_strategy
        ~on_tool_boundary
        agent
        user_blocks
    =
    run_blocks_detailed
      ~sw
      ?clock
      ?on_yield
      ?on_resume
      ?execution_store
      ~api_strategy
      ~on_tool_boundary
      agent
      user_blocks
    |> project_detailed_error
  ;;
end

let run_turn_stream_detailed ~sw ?clock ~on_event ?on_telemetry ?execution_store agent =
  let run ~sw () =
    run_turn_core_detailed
      ~sw
      ?clock
      ~api_strategy:(Stream { on_event; on_telemetry })
      agent
  in
  run_with_execution_scope ~sw ?execution_store agent (fun ~sw -> run ~sw ())
  |> Result.map (function
    | `Complete response -> `Complete response
    | `ToolsExecuted _ -> `ToolsExecuted
    | `TerminalToolCompleted receipt -> `TerminalToolCompleted receipt)
;;

let run_turn_stream ~sw ?clock ~on_event ?on_telemetry ?execution_store agent =
  run_turn_stream_detailed ~sw ?clock ~on_event ?on_telemetry ?execution_store agent
  |> project_detailed_error
;;

let save_journal agent path =
  match agent.options.journal with
  | Some j -> Durable_event.save_to_file j path
  | None -> Error "no journal"
;;
