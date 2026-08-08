(** Tool execution helpers — lookup, hooks, event_bus, parallel Eio fibers.

    These functions are parameterized by explicit fields rather than Agent.t
    to avoid circular module dependencies (Agent_tools is compiled before Agent). *)

open Types

let _log = Log.create ~module_name:"agent_tools" ()

type tool_failure_kind = Types.tool_failure_kind =
  | Validation_error
  | Recoverable_tool_error
  | Non_retryable_tool_error
  | Reported_tool_error
  | Unattributed_tool_error

include Agent_tool_execution_types

let observer_failure ~invocation exception_ backtrace =
  Llm_provider.Reserved_exn.reraise_if_reserved exception_;
  Log.error
    _log
    "tool observer failed"
    [ Log.S ("tool_use_id", Tool_contract.Invocation.tool_use_id invocation)
    ; Log.I ("turn", Tool_contract.Invocation.turn invocation)
    ; Log.I ("planned_index", Tool_contract.Invocation.planned_index invocation)
    ];
  Observer_failure { invocation; exception_; backtrace }
;;

let failure_summary = function
  | Hook_failure (Hook_execution_failed { hook_name; detail; _ }) ->
    Printf.sprintf "hook %s failed: %s" hook_name detail
  | Durability_failure { detail; _ } -> "durable execution failed: " ^ detail
  | Observer_failure { exception_; _ } -> Printexc.to_string exception_
;;

type scheduled_tool_use =
  { index : int
  ; id : string
  ; name : string
  ; input : Yojson.Safe.t
  ; execution_mode : Tool_contract.execution_mode
  ; completion : Tool_contract.completion
  }

type tool_index = (string, Tool.t) Hashtbl.t

let add_first tbl key value = if not (Hashtbl.mem tbl key) then Hashtbl.add tbl key value

let build_index tools =
  let by_name = Hashtbl.create (List.length tools) in
  List.iter
    (fun (tool : Tool.t) ->
       let name = tool.schema.name in
       add_first by_name name tool)
    tools;
  by_name
;;

let find_in_index (index : tool_index) name : Tool.t option = Hashtbl.find_opt index name

let tool_names_of_index index =
  Hashtbl.fold (fun name _ acc -> name :: acc) index [] |> List.sort_uniq String.compare
;;

let render_tool_names names =
  match names with
  | [] -> "(none)"
  | _ -> String.concat "," names
;;

let unknown_tool_failure ~requested ~available =
  let available_preview = render_tool_names available in
  ( Printf.sprintf "Tool not found: %s. Available tools: %s" requested available_preview
  , Validation_error )
;;

let resolve_tool_call tool_index name input = name, input, find_in_index tool_index name

let schedule_tool_use ~tool_index index (id, name, input) =
  let execution_mode, completion =
    match find_in_index tool_index name with
    | Some tool -> Tool.execution_mode tool, Tool.completion tool
    | None -> Tool_contract.Serial, Tool_contract.Continue_after_success
  in
  { index; id; name; input; execution_mode; completion }
;;

let hook_schedule_of_tool_use ~batch_index ~batch_size (tool_use : scheduled_tool_use)
  : Tool_contract.schedule
  =
  { planned_index = tool_use.index
  ; batch_index
  ; batch_size
  ; execution_mode = tool_use.execution_mode
  }
;;

exception Hook_observer_raised of exn * Printexc.raw_backtrace

let raise_hook_observer exn =
  let backtrace = Printexc.get_raw_backtrace () in
  raise (Hook_observer_raised (exn, backtrace))
;;

let reraise_hook_observer exn backtrace = Printexc.raise_with_backtrace exn backtrace

let invoke_hook ?on_hook_invoked ~tracer ~agent_name ~turn_count ~hook_name hook_opt event
  =
  try
    Tracing.with_span
      tracer
      { kind = Hook_invoke
      ; name = hook_name
      ; agent_name
      ; turn = turn_count
      ; extra = []
      ; links = []
      }
      (fun _ ->
         let decision = Hooks.invoke_validated ~hook_name hook_opt event in
         (match on_hook_invoked with
          | Some callback ->
            (try
               callback
                 ~invocation:(Hooks.invocation_of_event event)
                 ~hook_name
                 ~decision
                 ~detail:
                   (match event with
                    | Hooks.PreToolUse { tool_name; _ }
                    | Hooks.PostToolUse { tool_name; _ }
                    | Hooks.PostToolUseFailure { tool_name; _ } -> Some tool_name
                    | Hooks.BeforeTurn _
                    | Hooks.BeforeTurnParams _
                    | Hooks.AfterTurn _
                    | Hooks.OnStop _
                    | Hooks.OnError _
                    | Hooks.OnToolError _ -> None)
             with
             | exn -> raise_hook_observer exn)
          | None -> ());
         decision)
  with
  | Hook_observer_raised _ as exn -> raise exn
  | exn ->
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    (* A user-hook exception is converted to [HookFailed] inside
       [Hooks.invoke_validated]. Anything escaping the tracing envelope is
       therefore an observer/tracer failure and must reach the caller. *)
    raise_hook_observer exn
;;

let execution_failure_of_deferred = function
  | Deferred_hook_failure error -> Hook_failure error
  | Deferred_observer_failure { invocation; exception_; backtrace } ->
    Observer_failure { invocation; exception_; backtrace }
;;

let deferred_failure_summary deferred =
  failure_summary (execution_failure_of_deferred deferred)
;;

let hook_execution_error ~hook_name ~stage ~tool_name ~invocation ~detail =
  Hook_execution_failed { hook_name; stage; tool_name; invocation; detail }
;;

let invoke_post_hook
      ?on_hook_invoked
      ~tracer
      ~agent_name
      ~invocation
      ~hook_name
      ~tool_name
      hook_opt
      event
  =
  let turn_count = Tool_contract.Invocation.turn invocation in
  try
    match
      invoke_hook
        ?on_hook_invoked
        ~tracer
        ~agent_name
        ~turn_count
        ~hook_name
        hook_opt
        event
    with
    | Hooks.Continue -> None
    | Hooks.HookFailed { stage; detail } ->
      Some
        (Deferred_hook_failure
           (hook_execution_error ~hook_name ~stage ~tool_name ~invocation ~detail))
    | decision ->
      let stage = Hooks.stage_of_event event in
      Some
        (Deferred_hook_failure
           (hook_execution_error
              ~hook_name
              ~stage
              ~tool_name
              ~invocation
              ~detail:
                (Printf.sprintf
                   "illegal decision %s escaped hook validation"
                   (Hooks.decision_kind_to_string (Hooks.classify_decision decision)))))
  with
  | Hook_observer_raised (exception_, backtrace) ->
    Llm_provider.Reserved_exn.reraise_if_reserved exception_;
    Some (Deferred_observer_failure { invocation; exception_; backtrace })
;;

let resolve_dispatch dispatch =
  match dispatch.deferred_failure with
  | None -> Ok dispatch.result
  | Some (Deferred_hook_failure error) -> Error error
  | Some (Deferred_observer_failure { exception_; backtrace; _ }) ->
    reraise_hook_observer exception_ backtrace
;;

(** Find and execute a single tool, invoking PostToolUse hook.
    Returns a structured execution result. *)
let find_and_execute_tool_with_index
      ~context
      ~tool_index
      ~(hooks : Hooks.hooks)
      ~event_bus
      ~tracer
      ~agent_name
      ?correlation_id
      ?run_id
      ?on_hook_invoked
      ~publish_event_bus
      ~invocation
      name
      input
  =
  let id = Tool_contract.Invocation.tool_use_id invocation in
  let requested_name = name in
  let name, input, tool_opt = resolve_tool_call tool_index name input in
  let first_deferred_failure = ref None in
  let post_effect_observers = ref [] in
  let defer_observer observer =
    post_effect_observers := observer :: !post_effect_observers
  in
  let record_deferred_failure failure =
    match !first_deferred_failure with
    | None -> first_deferred_failure := Some failure
    | Some primary ->
      let retained, suppressed =
        match primary, failure with
        | Deferred_hook_failure _, Deferred_observer_failure _ ->
          first_deferred_failure := Some failure;
          failure, primary
        | _ -> primary, failure
      in
      Log.error
        _log
        "additional tool dispatch failure"
        [ Log.S ("tool", name)
        ; Log.S ("tool_use_id", id)
        ; Log.S ("retained", deferred_failure_summary retained)
        ; Log.S ("suppressed", deferred_failure_summary suppressed)
        ]
  in
  let record_deferred_exception exception_ backtrace =
    Llm_provider.Reserved_exn.reraise_if_reserved exception_;
    record_deferred_failure
      (Deferred_observer_failure { invocation; exception_; backtrace })
  in
  (* ToolCalled event — capture the published envelope's run_id so the
     matching ToolCompleted records it as caused_by, preserving the
     call -> completion causation chain per tool invocation (#877).
     Using [ev.meta.run_id] works whether the caller supplies
     [~run_id] explicitly or we fall back to the fresh id minted by
     [mk_event]. *)
  let tool_called_run_id =
    match publish_event_bus, event_bus with
    | false, _ -> None
    | true, Some bus ->
      let ev =
        Event_bus.mk_event
          ?correlation_id
          ?run_id
          (ToolCalled { invocation; agent_name; tool_name = name; input })
      in
      (try
         Event_bus.publish bus ev;
         Some ev.meta.run_id
       with
       | exception_ ->
         let backtrace = Printexc.get_raw_backtrace () in
         record_deferred_exception exception_ backtrace;
         None)
    | true, None -> None
  in
  let dispatch =
    match tool_opt with
    | Some tool ->
      let validation_error_result ~input message =
        { invocation
        ; tool_name = name
        ; input
        ; content = message
        ; outcome =
            Tool_failed
              { failure_kind = Validation_error; error_class = Some Types.Deterministic }
        }
      in
      let emit_post_tool_use_failure ~input message =
        invoke_post_hook
          ?on_hook_invoked
          ~tracer
          ~agent_name
          ~invocation
          ~hook_name:"post_tool_use_failure"
          ~tool_name:name
          hooks.post_tool_use_failure
          (Hooks.PostToolUseFailure
             { invocation; tool_name = name; input; error = message })
      in
      (* Tool inputs cross this boundary unchanged. The schema either accepts
           the exact JSON value or produces a typed validation failure for the
           model to correct in a later native ToolUse block. *)
      let validated_input =
        match Tool_input_validation.validate tool.schema input with
        | Tool_input_validation.Valid exact_input -> Ok exact_input
        | Tool_input_validation.Invalid errors ->
          let message =
            Tool_input_validation.format_errors_inline ~tool_name:name ~args:input errors
          in
          defer_observer (fun () ->
            emit_post_tool_use_failure ~input message
            |> Option.iter record_deferred_failure);
          Error message
      in
      (match validated_input with
       | Error message ->
         { result = validation_error_result ~input message; deferred_failure = None }
       | Ok exact_input ->
         let t0 = Unix.gettimeofday () in
         let result =
           Agent_tool_terminal_boundary.execute_handler ~tool ~name (fun () ->
             Tool.execute ~context ~invocation tool exact_input)
         in
         let duration_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
         let result_bytes =
           match result with
           | Ok { content; _meta = _ } -> String.length content
           | Error { message; _ } -> String.length message
         in
         defer_observer (fun () ->
           invoke_post_hook
             ?on_hook_invoked
             ~tracer
             ~agent_name
             ~invocation
             ~hook_name:"post_tool_use"
             ~tool_name:name
             hooks.post_tool_use
             (Hooks.PostToolUse
                { invocation
                ; tool_name = name
                ; input = exact_input
                ; output = result
                ; result_bytes
                ; duration_ms
                })
           |> Option.iter record_deferred_failure);
         (match result with
          | Ok _ -> ()
          | Error { message; _ } ->
            defer_observer (fun () ->
              invoke_post_hook
                ?on_hook_invoked
                ~tracer
                ~agent_name
                ~invocation
                ~hook_name:"post_tool_use_failure"
                ~tool_name:name
                hooks.post_tool_use_failure
                (Hooks.PostToolUseFailure
                   { invocation; tool_name = name; input = exact_input; error = message })
              |> Option.iter record_deferred_failure);
            (* [OnToolError] is the compact error projection. The exact
               invocation remains shared with the richer failure hook. *)
            defer_observer (fun () ->
              invoke_post_hook
                ?on_hook_invoked
                ~tracer
                ~agent_name
                ~invocation
                ~hook_name:"on_tool_error"
                ~tool_name:name
                hooks.on_tool_error
                (Hooks.OnToolError { invocation; tool_name = name; error = message })
              |> Option.iter record_deferred_failure));
         let content, outcome =
           match result with
           | Ok { content; _meta = _ } -> content, Tool_succeeded
           | Error { message; recoverable; error_class } ->
             let failure_kind =
               if recoverable then Recoverable_tool_error else Non_retryable_tool_error
             in
             message, Tool_failed { failure_kind; error_class }
         in
         { result =
             { invocation; tool_name = name; input = exact_input; content; outcome }
         ; deferred_failure = None
         })
    | None ->
      (* Tool dispatch failure (the LLM asked for a tool that isn't
         registered). Distinct from OnToolError — that fires when a
         tool actually ran and returned Error. This is a configuration
         / routing mistake, so it belongs on the general OnError
         channel. Unknown names are always typed as validation errors; the
         available names remain diagnostic data only. *)
      let available = tool_names_of_index tool_index in
      let message, failure_kind =
        unknown_tool_failure ~requested:requested_name ~available
      in
      Log.warn
        _log
        "tool not found"
        [ Log.S ("tool", requested_name)
        ; Log.S ("available_tools", render_tool_names available)
        ];
      defer_observer (fun () ->
        invoke_post_hook
          ?on_hook_invoked
          ~tracer
          ~agent_name
          ~invocation
          ~hook_name:"on_error"
          ~tool_name:requested_name
          hooks.on_error
          (Hooks.OnError
             { invocation = Some invocation
             ; detail = message
             ; context = "agent_tools.find_and_execute_tool"
             })
        |> Option.iter record_deferred_failure);
      { result =
          { invocation
          ; tool_name = requested_name
          ; input
          ; content = message
          ; outcome = Tool_failed { failure_kind; error_class = Some Types.Deterministic }
          }
      ; deferred_failure = None
      }
  in
  (* ToolCompleted event *)
  defer_observer (fun () ->
    match publish_event_bus, event_bus with
    | false, _ -> ()
    | true, Some bus ->
      let output_content = dispatch.result.content in
      let output =
        Types.tool_result_of_outcome ~content:output_content dispatch.result.outcome
      in
      (try
         Event_bus.publish
           bus
           (Event_bus.mk_event
              ?correlation_id
              ?run_id
              ?caused_by:tool_called_run_id
              (ToolCompleted { invocation; agent_name; tool_name = name; output }))
       with
       | exception_ ->
         let backtrace = Printexc.get_raw_backtrace () in
         record_deferred_exception exception_ backtrace)
    | true, None -> ());
  { result = dispatch.result
  ; finish_observers =
      (fun () ->
        List.rev !post_effect_observers |> List.iter (fun observe -> observe ());
        { dispatch with deferred_failure = !first_deferred_failure })
  }
;;

let find_and_execute_tool
      ~context
      ~tools
      ~(hooks : Hooks.hooks)
      ~event_bus
      ~tracer
      ~agent_name
      ?correlation_id
      ?run_id
      ?on_hook_invoked
      ~invocation
      name
      input
  =
  let tool_index = build_index tools in
  try
    let pending =
      find_and_execute_tool_with_index
        ~context
        ~tool_index
        ~hooks
        ~event_bus
        ~tracer
        ~agent_name
        ?correlation_id
        ?run_id
        ?on_hook_invoked
        ~publish_event_bus:true
        ~invocation
        name
        input
    in
    pending.finish_observers () |> resolve_dispatch
  with
  | Hook_observer_raised (exn, backtrace) -> reraise_hook_observer exn backtrace
;;

exception Abort_tool_dispatch

let execute_scheduled_tool
      ~context
      ~tools:_
      ~tool_index
      ~(hooks : Hooks.hooks)
      ~event_bus
      ?tool_approval
      ?journal
      ~tracer
      ~agent_name
      ~turn_count
      ~(usage : Types.usage_stats)
      ?correlation_id
      ?run_id
      ?on_tool_execution_started
      ?on_tool_execution_finished
      ?on_hook_invoked
      ~(schedule : Tool_contract.schedule)
      (tool_use : scheduled_tool_use)
  =
  let { index; id; name; input; _ } = tool_use in
  let invocation =
    Tool_contract.Invocation.create
      ~tool_use_id:id
      ~turn:turn_count
      ~schedule
      ~completion:tool_use.completion
  in
  let id = Tool_contract.Invocation.tool_use_id invocation in
  let turn_count = Tool_contract.Invocation.turn invocation in
  let completed_dispatch : tool_dispatch option ref = ref None in
  let first_failure = ref None in
  let record_failure failure =
    match !first_failure with
    | None -> first_failure := Some failure
    | Some primary ->
      let retained, suppressed =
        if failure_priority failure > failure_priority primary
        then (
          first_failure := Some failure;
          failure, primary)
        else primary, failure
      in
      Log.error
        _log
        "additional tool execution failure"
        [ Log.S ("tool", name)
        ; Log.S ("tool_use_id", id)
        ; Log.S ("retained", failure_summary retained)
        ; Log.S ("suppressed", failure_summary suppressed)
        ]
  in
  let record_caught_exception exception_ backtrace =
    Llm_provider.Reserved_exn.reraise_if_reserved exception_;
    record_failure (observer_failure ~invocation exception_ backtrace)
  in
  let observe_before_completion callback =
    try callback () with
    | Hook_observer_raised (exception_, backtrace) ->
      record_caught_exception exception_ backtrace;
      raise Abort_tool_dispatch
    | exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      record_caught_exception exception_ backtrace;
      raise Abort_tool_dispatch
  in
  let observe_after_completion callback =
    try callback () with
    | Hook_observer_raised (exception_, backtrace) ->
      record_caught_exception exception_ backtrace
    | exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      record_caught_exception exception_ backtrace
  in
  let outcome () =
    { index
    ; completed_result =
        Option.map (fun (dispatch : tool_dispatch) -> dispatch.result) !completed_dispatch
    ; completion =
        Agent_tool_terminal_boundary.completed_dispatch
          tool_use.completion
          !completed_dispatch
    ; failure = !first_failure
    }
  in
  let observe_started ~tool_name ~input =
    match on_tool_execution_started with
    | Some callback -> callback ~invocation ~tool_name ~input
    | None -> ()
  in
  let begin_effect ~tool_name ~input =
    let t0_tool = Unix.gettimeofday () in
    let pending =
      find_and_execute_tool_with_index
        ~context
        ~tool_index
        ~hooks
        ~event_bus
        ~tracer
        ~agent_name
        ?correlation_id
        ?run_id
        ?on_hook_invoked
        ~publish_event_bus:true
        ~invocation
        tool_name
        input
    in
    completed_dispatch
    := Some ({ result = pending.result; deferred_failure = None } : tool_dispatch);
    pending, (Unix.gettimeofday () -. t0_tool) *. 1000.0
  in
  let finish_effect pending ~tool_name =
    let dispatch = pending.finish_observers () in
    completed_dispatch := Some dispatch;
    Option.iter
      (fun deferred -> record_failure (execution_failure_of_deferred deferred))
      dispatch.deferred_failure;
    observe_after_completion (fun () ->
      match on_tool_execution_finished with
      | Some callback ->
        callback
          ~invocation
          ~tool_name
          ~content:dispatch.result.content
          ~is_error:(Types.tool_result_outcome_is_error dispatch.result.outcome)
      | None -> ());
    dispatch
  in
  let execute_durable durable_invocation =
    match
      Execution_agent_scope.execute_phased
        durable_invocation
        ~invoke:(fun ~start_child ~tool_name ~input ->
          observe_before_completion (fun () -> observe_started ~tool_name ~input);
          Execution_context.with_child_scope_factory start_child (fun () ->
            let pending, _duration_ms = begin_effect ~tool_name ~input in
            ( (pending.result.content, pending.result.outcome)
            , fun () ->
                let (_ : tool_dispatch) = finish_effect pending ~tool_name in
                () )))
    with
    | Error error ->
      (* The effect may already have returned, but without an atomic settlement
         there is no result authority to expose to the transcript. *)
      completed_dispatch := None;
      record_failure
        (Durability_failure
           { invocation; detail = Execution_agent_scope.error_to_string error });
      raise Abort_tool_dispatch
    | Ok (Execution_agent_scope.Executed (result, _, _))
    | Ok (Execution_agent_scope.Replayed result) ->
      let dispatch =
        match !completed_dispatch with
        | Some dispatch -> dispatch
        | None ->
          { result =
              { invocation = result.invocation
              ; tool_name = result.tool_name
              ; input = result.input
              ; content = result.content
              ; outcome = result.outcome
              }
          ; deferred_failure = None
          }
      in
      completed_dispatch := Some dispatch;
      dispatch
  in
  let with_tool_span run =
    Tracing.with_span
      tracer
      { kind = Tool_exec; name; agent_name; turn = turn_count; extra = []; links = [] }
      (fun _tracer -> run ())
  in
  let durability_failure error =
    record_failure
      (Durability_failure
         { invocation; detail = Execution_agent_scope.error_to_string error });
    raise Abort_tool_dispatch
  in
  let settle_existing_block durable result =
    match Agent_tool_pre_execution_gate.settle_existing_block durable result with
    | Ok result -> result
    | Error error -> durability_failure error
  in
  let settle_gate ?settle_blocked execute_admitted =
    let decision =
      invoke_hook
        ?on_hook_invoked
        ~tracer
        ~agent_name
        ~turn_count
        ~hook_name:"pre_tool_use"
        hooks.pre_tool_use
        (Hooks.PreToolUse
           { invocation
           ; tool_name = name
           ; input
           ; accumulated_cost_usd = usage.Types.estimated_cost_usd
           })
    in
    let settlement =
      Agent_tool_pre_execution_gate.settle
        ?tool_approval
        ?correlation_id
        ?run_id
        ~event_bus
        ~agent_name
        ~invocation
        ~tool_name:name
        ~input
        decision
    in
    match
      Agent_tool_pre_execution_gate.scheduled_settlement
        ?settle_blocked
        ~index
        ~invocation
        ~tool_name:name
        ~input
        settlement
    with
    | Agent_tool_pre_execution_gate.Run_admitted -> execute_admitted ()
    | Agent_tool_pre_execution_gate.Return_outcome outcome -> outcome
  in
  try
    let execution_provider = Execution_context.provider_attempt () in
    let existing =
      match execution_provider with
      | None -> Ok None
      | Some provider ->
        Execution_agent_scope.find_invocation provider ~invocation ~tool_name:name ~input
    in
    match existing with
    | Error error -> durability_failure error
    | Ok (Some durable) ->
      let execute_existing () =
        let (_ : tool_dispatch) = with_tool_span (fun () -> execute_durable durable) in
        outcome ()
      in
      (match Execution_agent_scope.invocation_progress durable with
       | Error error -> durability_failure error
       | Ok Execution_agent_scope.Invocation_unattempted ->
         settle_gate ~settle_blocked:(settle_existing_block durable) execute_existing
       | Ok Execution_agent_scope.Invocation_attempted_or_settled -> execute_existing ())
    | Ok None ->
      let execute_admitted () =
        let idem_key = Durable_event.make_idempotency_key ~tool_name:name ~input in
        try
          let dispatch =
            with_tool_span (fun () ->
              match execution_provider with
              | Some provider ->
                (match
                   Execution_agent_scope.open_invocation
                     provider
                     ~invocation
                     ~tool_name:name
                     ~input
                 with
                 | Error error -> durability_failure error
                 | Ok durable_invocation -> execute_durable durable_invocation)
              | None ->
                observe_before_completion (fun () ->
                  observe_started ~tool_name:name ~input;
                  match journal with
                  | Some j ->
                    Agent_execution_event_writer.append
                      j
                      (Tool_called
                         { turn = Tool_contract.Invocation.turn invocation
                         ; tool_name = name
                         ; idempotency_key = idem_key
                         ; input_hash = Digest.string (Yojson.Safe.to_string input)
                         ; timestamp = Unix.gettimeofday ()
                         })
                  | None -> ());
                let pending, duration_ms_tool = begin_effect ~tool_name:name ~input in
                let dispatch = finish_effect pending ~tool_name:name in
                observe_after_completion (fun () ->
                  match journal with
                  | Some j ->
                    Agent_execution_event_writer.append
                      j
                      (Tool_completed
                         { turn = Tool_contract.Invocation.turn invocation
                         ; tool_name = name
                         ; idempotency_key = idem_key
                         ; output_json = `String dispatch.result.content
                         ; is_error =
                             Types.tool_result_outcome_is_error dispatch.result.outcome
                         ; duration_ms = duration_ms_tool
                         ; timestamp = Unix.gettimeofday ()
                         })
                  | None -> ());
                dispatch)
          in
          completed_dispatch := Some dispatch;
          outcome ()
        with
        | Abort_tool_dispatch -> outcome ()
        | Hook_observer_raised (exception_, backtrace) ->
          record_caught_exception exception_ backtrace;
          outcome ()
        | exception_ ->
          let backtrace = Printexc.get_raw_backtrace () in
          record_caught_exception exception_ backtrace;
          outcome ()
      in
      settle_gate execute_admitted
  with
  | Hook_observer_raised (exception_, backtrace) ->
    record_caught_exception exception_ backtrace;
    outcome ()
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    record_caught_exception exception_ backtrace;
    outcome ()
;;

let execute_tools
      ~context
      ~tools
      ~(hooks : Hooks.hooks)
      ?tool_approval
      ~event_bus
      ?journal
      ~tracer
      ~agent_name
      ~turn_count
      ~(usage : Types.usage_stats)
      ?correlation_id
      ?run_id
      ?before_tool_execution
      ?on_tool_execution_started
      ?on_tool_execution_finished
      ?on_hook_invoked
      tool_uses
  =
  let tool_index = build_index tools in
  let tool_use_blocks = Agent_tool_terminal_boundary.tool_use_blocks tool_uses in
  let scheduled = List.mapi (schedule_tool_use ~tool_index) tool_use_blocks in
  let plan =
    Agent_tool_batch_plan.create
      ~execution_mode:(fun tool_use -> tool_use.execution_mode)
      ~completion:(fun tool_use -> tool_use.completion)
      scheduled
  in
  let run_one =
    execute_scheduled_tool
      ~context
      ~tools
      ~tool_index
      ~hooks
      ~event_bus
      ?tool_approval
      ?journal
      ~tracer
      ~agent_name
      ~turn_count
      ~usage
      ?correlation_id
      ?run_id
      ?on_tool_execution_started
      ?on_tool_execution_finished
      ?on_hook_invoked
  in
  let collect_batch (outcomes : scheduled_tool_outcome list) =
    let completed =
      List.filter_map
        (fun (outcome : scheduled_tool_outcome) ->
           Option.map (fun result -> outcome.index, result) outcome.completed_result)
        outcomes
    in
    let failure =
      List.fold_left
        (fun selected (outcome : scheduled_tool_outcome) ->
           match outcome.failure with
           | None -> selected
           | Some candidate -> prefer_failure selected candidate)
        None
        outcomes
    in
    let completion =
      List.fold_left
        (fun selected (outcome : scheduled_tool_outcome) ->
           match selected, outcome.completion with
           | (Terminal_completed _ | Terminal_failed _), _ -> selected
           | Continue_after_batch, candidate -> candidate)
        Continue_after_batch
        outcomes
    in
    completed, completion, failure
  in
  let ordered_results completed =
    completed
    |> List.sort (fun (left_index, _) (right_index, _) ->
      Int.compare left_index right_index)
    |> List.map snd
  in
  let rec run_batches batch_index completed completion = function
    | [] -> Ok { completed_results = ordered_results completed; completion }
    | batch :: rest ->
      let batch_results =
        match batch with
        | Agent_tool_batch_plan.Serial_batch tool_use ->
          let schedule = hook_schedule_of_tool_use ~batch_index ~batch_size:1 tool_use in
          [ run_one ~schedule tool_use ]
        | Agent_tool_batch_plan.Concurrent_batch tool_uses ->
          let batch_size = List.length tool_uses in
          tool_uses
          |> List.map (fun tool_use ->
            let schedule = hook_schedule_of_tool_use ~batch_index ~batch_size tool_use in
            tool_use, schedule)
          |> Eio.Fiber.List.map (fun (tool_use, schedule) -> run_one ~schedule tool_use)
      in
      let batch_completed, batch_completion, failure = collect_batch batch_results in
      let completed = List.rev_append batch_completed completed in
      let completion =
        match completion, batch_completion with
        | (Terminal_completed _ | Terminal_failed _), _ -> completion
        | Continue_after_batch, candidate -> candidate
      in
      (match failure with
       | Some cause ->
         Error { completed_results = ordered_results completed; completion; cause }
       | None -> run_batches (batch_index + 1) completed completion rest)
  in
  match plan with
  | Agent_tool_batch_plan.Rejected_terminal_mix scheduled ->
    let batch_size = List.length scheduled in
    Ok
      (Agent_tool_terminal_boundary.rejected_report
         ~turn:turn_count
         ~schedule:(hook_schedule_of_tool_use ~batch_index:0 ~batch_size)
         ~completion:(fun tool_use -> tool_use.completion)
         ~id:(fun tool_use -> tool_use.id)
         ~name:(fun tool_use -> tool_use.name)
         ~input:(fun tool_use -> tool_use.input)
         scheduled)
  | Agent_tool_batch_plan.Admitted batches ->
    if batches <> [] then Option.iter (fun callback -> callback ()) before_tool_execution;
    run_batches 0 [] Continue_after_batch batches
;;

let recovered_batch_completion = Agent_tool_terminal_boundary.recovered_batch_completion
