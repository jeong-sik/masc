open Result.Syntax

let config_error ~field detail =
  Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field; detail })
;;

let internal_error detail = Agent_sdk.Error.Internal detail

let text_of_blocks ~runtime_label ~field blocks =
  let rec loop texts = function
    | [] -> Ok (String.concat "\n" (List.rev texts))
    | Agent_sdk.Types.Text text :: rest -> loop (text :: texts) rest
    | _ :: _ ->
      Error
        (config_error
           ~field
           (runtime_label ^ " official-client projection admits text blocks only"))
  in
  loop [] blocks
;;

type history_projection =
  { messages : Agent_sdk.Types.message list
  ; dropped_tool_messages : int
  ; dropped_messages : int
  ; dropped_blocks : int
  }

(* The official-client wire admits text-only user/assistant history
   ([text_of_blocks] rejects every other block, and Tool-role messages are not
   representable at all). Project the representable subset instead of erasing
   the whole history, and account for every dropped part so the caller can
   surface the loss (masc#27812). *)
let project_official_history messages =
  let project
      (kept, dropped_tool, dropped_msgs, dropped_blocks)
      (message : Agent_sdk.Types.message) =
    match message.role with
    | Tool -> kept, dropped_tool + 1, dropped_msgs, dropped_blocks
    | System | User | Assistant ->
      let text_blocks, other_blocks =
        List.partition
          (function
            | Agent_sdk.Types.Text _ -> true
            | _ -> false)
          message.content
      in
      let dropped_blocks = dropped_blocks + List.length other_blocks in
      (match text_blocks, message.content with
       | [], _ :: _ -> kept, dropped_tool, dropped_msgs + 1, dropped_blocks
       | _, _ ->
         ( { message with content = text_blocks } :: kept
         , dropped_tool
         , dropped_msgs
         , dropped_blocks ))
  in
  let kept, dropped_tool_messages, dropped_messages, dropped_blocks =
    List.fold_left project ([], 0, 0, 0) messages
  in
  { messages = List.rev kept
  ; dropped_tool_messages
  ; dropped_messages
  ; dropped_blocks
  }
;;

let history_projection_lossless projection =
  projection.dropped_tool_messages = 0
  && projection.dropped_messages = 0
  && projection.dropped_blocks = 0
;;

let user_message text : Agent_sdk.Types.message =
  { role = User
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let system_message text : Agent_sdk.Types.message =
  { role = System
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let last_tool_results messages =
  messages
  |> List.rev
  |> List.find_map (fun (message : Agent_sdk.Types.message) ->
    match message.role with
    | Tool ->
      Some
        (List.filter_map
           (function
             | Agent_sdk.Types.ToolResult { content; outcome; _ } ->
               Some (Agent_sdk.Types.tool_result_of_outcome ~content outcome)
             | _ -> None)
           message.content)
    | System | User | Assistant -> None)
  |> Option.value ~default:[]
;;

let hook_error ~runtime_label ~hook_name ~stage detail =
  internal_error
    (Printf.sprintf
       "%s runtime %s hook failed at %s: %s"
       runtime_label
       hook_name
       (Agent_sdk.Hooks.hook_stage_to_string stage)
       detail)
;;

let illegal_hook_decision ~runtime_label ~hook_name decision =
  config_error
    ~field:"hooks"
    (Printf.sprintf
       "%s runtime %s hook returned unsupported decision %s"
       runtime_label
       hook_name
       (Agent_sdk.Hooks.decision_kind_to_string
          (Agent_sdk.Hooks.classify_decision decision)))
;;

let invoke_turn_hook ~keeper_name ~turn_count ~hook_name hook event =
  Agent_sdk.Agent_tools.invoke_hook
    ~tracer:Agent_sdk.Tracing.null
    ~agent_name:keeper_name
    ~turn_count
    ~hook_name
    hook
    event
;;

let lifecycle_outcome = function
  | Error error -> Agent_sdk.Agent_lifecycle_events.Failed error
  | Ok ({ response; stop_reason; _ } : Runtime_agent.run_result) ->
    (match stop_reason with
     | Runtime_agent.Completed ->
       Agent_sdk.Agent_lifecycle_events.Completed response
     | Runtime_agent.InputRequired { request; _ } ->
       Agent_sdk.Agent_lifecycle_events.Input_required request
     | Runtime_agent.Yielded_to_chat_waiting { turns_used }
     | Runtime_agent.Yielded_to_durable_stimulus { turns_used }
     | Runtime_agent.Awaiting_external_effect { turns_used }
     | Runtime_agent.Yielded_after_repeated_tool_call { turns_used; _ } ->
       Agent_sdk.Agent_lifecycle_events.Yielded { turn = turns_used })
;;

let with_run_lifecycle_events ~event_bus ~keeper_name run =
  Agent_sdk.Agent_lifecycle_events.with_run_lifecycle_events
    ~event_bus
    ~agent_name:keeper_name
    ~raw_trace:None
    ~current_run_id:(fun () -> None)
    ~classify:lifecycle_outcome
    run
;;

type prepared_turn =
  { messages : Agent_sdk.Types.message list
  ; system_prompt : string
  ; tools : Agent_sdk.Tool.t list
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  }

let resolve_reasoning_effort ~enable_thinking ~reasoning_effort =
  match enable_thinking with
  | Some _ ->
    Error
      (config_error
         ~field:"enable_thinking"
         "official-client runtimes do not project enable_thinking; use reasoning_effort for explicit control")
  | None -> Ok reasoning_effort
;;

let prepare_turn ~runtime_label ~keeper_name ~turn_count ~system_prompt ~tools
    ~initial_messages ~model_input_projection ~hooks =
  let hooks = Option.value hooks ~default:Agent_sdk.Hooks.empty in
  let before_turn =
    invoke_turn_hook
      ~keeper_name
      ~turn_count
      ~hook_name:"before_turn"
      hooks.before_turn
      (Agent_sdk.Hooks.BeforeTurn { turn = turn_count; messages = initial_messages })
  in
  let* messages =
    match before_turn with
    | Continue -> Ok initial_messages
    | Nudge text -> Ok (initial_messages @ [ user_message text ])
    | HookFailed { stage; detail } ->
      Error (hook_error ~runtime_label ~hook_name:"before_turn" ~stage detail)
    | decision ->
      Error (illegal_hook_decision ~runtime_label ~hook_name:"before_turn" decision)
  in
  let current_params = Agent_sdk.Hooks.default_turn_params in
  let before_turn_params =
    invoke_turn_hook
      ~keeper_name
      ~turn_count
      ~hook_name:"before_turn_params"
      hooks.before_turn_params
      (Agent_sdk.Hooks.BeforeTurnParams
         { turn = turn_count
         ; messages
         ; last_tool_results = last_tool_results messages
         ; current_params
         ; reasoning = Agent_sdk.Hooks.empty_reasoning_summary
         })
  in
  let* turn_params =
    match before_turn_params with
    | Continue -> Ok current_params
    | AdjustParams params -> Ok params
    | HookFailed { stage; detail } ->
      Error (hook_error ~runtime_label ~hook_name:"before_turn_params" ~stage detail)
    | decision ->
      Error
        (illegal_hook_decision
           ~runtime_label
           ~hook_name:"before_turn_params"
           decision)
  in
  let messages =
    match turn_params.extra_system_context with
    | None -> messages
    | Some text -> messages @ [ system_message text ]
  in
  let* messages =
    match model_input_projection with
    | None -> Ok messages
    | Some project ->
      (try
         match project messages with
         | Ok projected -> Ok projected
         | Error detail -> Error (config_error ~field:"model_input_projection" detail)
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Error
           (internal_error
              (runtime_label
               ^ " runtime model input projection raised: "
               ^ Printexc.to_string exn)))
  in
  let system_prompt =
    Option.value turn_params.system_prompt_override ~default:system_prompt
  in
  let unsupported_parameter field value =
    match value with
    | None -> Ok ()
    | Some _ ->
      Error
        (config_error
           ~field
           (runtime_label
            ^ " official-client runtime does not project this turn parameter"))
  in
  let* () = unsupported_parameter "temperature" turn_params.temperature in
  let* () = unsupported_parameter "thinking_budget" turn_params.thinking_budget in
  let* () = unsupported_parameter "preserve_thinking" turn_params.preserve_thinking in
  let* reasoning_effort =
    resolve_reasoning_effort
      ~enable_thinking:turn_params.enable_thinking
      ~reasoning_effort:turn_params.reasoning_effort
  in
  let* tools =
    match turn_params.tool_choice with
    | None | Some Auto -> Ok tools
    | Some None_ -> Ok []
    | Some ((Any | Tool _) as choice) ->
      Error
        (config_error
           ~field:"tool_choice"
           (Printf.sprintf
              "%s official-client tools do not support forced tool choice %s"
              runtime_label
              (Yojson.Safe.to_string
                 (Agent_sdk.Types.tool_choice_to_json choice))))
  in
  Ok { messages; system_prompt; tools; reasoning_effort }
;;

type dynamic_tool_result =
  { success : bool
  ; content : string
  }

type dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

let tool_hook_error_to_string = function
  | Agent_sdk.Agent_tools.Hook_execution_failed
      { hook_name; stage; tool_name; detail; _ } ->
    Printf.sprintf
      "%s hook failed at %s for tool %s: %s"
      hook_name
      (Agent_sdk.Hooks.hook_stage_to_string stage)
      tool_name
      detail
;;

let record_terminal_error terminal_error detail =
  if Option.is_none !terminal_error then terminal_error := Some detail
;;

type raw_trace_stage =
  | Run_start
  | Assistant_block
  | Tool_start
  | Tool_finish
  | Run_finish

let raw_trace_stage_label = function
  | Run_start -> "run_start"
  | Assistant_block -> "assistant_block"
  | Tool_start -> "tool_start"
  | Tool_finish -> "tool_finish"
  | Run_finish -> "run_finish"
;;

let observe_raw_trace ~keeper_name ~stage observe =
  match
    try observe () with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
    | exn -> Error (Agent_sdk.Error.Internal (Printexc.to_string exn))
  with
  | Ok value -> Some value
  | Error error ->
    let stage = raw_trace_stage_label stage in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string TraceEmitFailures)
      ~labels:[ "keeper", keeper_name; "source", "official_client_raw"; "stage", stage ]
      ();
    Log.Keeper.warn
      ~keeper_name
      "official-client RAW trace observation failed at %s; authoritative execution continues: %s"
      stage
      (Agent_sdk.Error.to_string error);
    None
;;

let record_raw_tool_started ~keeper_name ~raw_trace_run ~invocation ~tool_name ~input =
  match raw_trace_run with
  | None -> false
  | Some active ->
    Option.is_some
      (observe_raw_trace ~keeper_name ~stage:Tool_start (fun () ->
         Agent_sdk.Raw_trace.record_tool_execution_started
           active
           ~invocation
           ~tool_name
           ~tool_input:input))
;;

let finish_dynamic_tool_raw
      ~keeper_name
      ~raw_trace_started
      ~raw_trace_run
      ~invocation
      ~tool_name
      result
  =
  match raw_trace_started, raw_trace_run with
  | false, _ | _, None -> result
  | true, Some active ->
    ignore
      (observe_raw_trace ~keeper_name ~stage:Tool_finish (fun () ->
         Agent_sdk.Raw_trace.record_tool_execution_finished
           active
           ~invocation
           ~tool_name
           ~tool_result:result.content
           ~tool_error:(not result.success)
           ()));
    result
;;

let apply_context_injection ~runtime_label ~terminal_error ~context
    ~context_injector ~tool_name ~input ~content ~outcome =
  match context_injector with
  | None -> ()
  | Some inject ->
    let output = Agent_sdk.Types.tool_result_of_outcome ~content outcome in
    (try
       match inject ~tool_name ~input ~output with
       | None -> ()
       | Some (injection : Agent_sdk.Hooks.injection) ->
         List.iter
           (fun (key, value) -> Agent_sdk.Context.set context key value)
           injection.context_updates;
         if injection.extra_messages <> []
         then
           record_terminal_error
             terminal_error
             (runtime_label
              ^ " dynamic tool context injection produced extra_messages, which cannot be projected into an active official-client turn")
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       record_terminal_error
         terminal_error
         (runtime_label
          ^ " dynamic tool context injection raised after execution: "
          ^ Printexc.to_string exn))
;;

let dynamic_tool_of_oas ~runtime_label ~keeper_name ~turn_count ~context ~tools
    ~(hooks : Agent_sdk.Hooks.hooks) ~event_bus ~context_injector ~terminal_error
    ~raw_trace_run ~next_dynamic_invocation_index
    (tool : Agent_sdk.Tool.t) =
  { name = tool.schema.name
  ; description = tool.schema.description
  ; input_schema = Agent_sdk.Types.params_to_input_schema tool.schema.parameters
  ; call =
      (fun ~call_id input ->
        let schedule : Agent_sdk.Tool_contract.schedule =
          { planned_index = Atomic.fetch_and_add next_dynamic_invocation_index 1
          ; batch_index = 0
          ; batch_size = 1
          ; execution_mode = Agent_sdk.Tool.execution_mode tool
          }
        in
        let invocation =
          Agent_sdk.Tool_contract.Invocation.create
            ~tool_use_id:call_id
            ~turn:turn_count
            ~schedule
            ~completion:(Agent_sdk.Tool.completion tool)
        in
        let raw_trace_started =
          record_raw_tool_started
            ~keeper_name
            ~raw_trace_run
            ~invocation
            ~tool_name:tool.schema.name
            ~input
        in
        let settle =
          finish_dynamic_tool_raw
            ~keeper_name
            ~raw_trace_started
            ~raw_trace_run
            ~invocation
            ~tool_name:tool.schema.name
        in
        let execute () =
          let pre_tool_use =
            invoke_turn_hook
              ~keeper_name
              ~turn_count
              ~hook_name:"pre_tool_use"
              hooks.pre_tool_use
              (Agent_sdk.Hooks.PreToolUse
                 { invocation
                 ; tool_name = tool.schema.name
                 ; input
                 ; accumulated_cost_usd = 0.0
                 })
          in
          match pre_tool_use with
          | Block detail -> { success = false; content = detail }
          | HookFailed { stage; detail } ->
            let detail =
              Printf.sprintf
                "pre_tool_use hook failed at %s: %s"
                (Agent_sdk.Hooks.hook_stage_to_string stage)
                detail
            in
            { success = false; content = detail }
          | (ElicitToolApproval _ | ElicitInput _) as decision ->
            let detail =
              Printf.sprintf
                "%s dynamic tool cannot settle hook decision %s without a host approval callback"
                runtime_label
                (Agent_sdk.Hooks.decision_kind_to_string
                   (Agent_sdk.Hooks.classify_decision decision))
            in
            record_terminal_error terminal_error detail;
            { success = false; content = detail }
          | (AdjustParams _ | Nudge _) as decision ->
            let detail =
              Printf.sprintf
                "%s dynamic tool received illegal pre_tool_use decision %s"
                runtime_label
                (Agent_sdk.Hooks.decision_kind_to_string
                   (Agent_sdk.Hooks.classify_decision decision))
            in
            record_terminal_error terminal_error detail;
            { success = false; content = detail }
          | Continue ->
            (match
               Agent_sdk.Agent_tools.find_and_execute_tool
                 ~context
                 ~tools
                 ~hooks
                 ~event_bus
                 ~tracer:Agent_sdk.Tracing.null
                 ~agent_name:keeper_name
                 ~invocation
                 tool.schema.name
                 input
             with
             | Ok result ->
               apply_context_injection
                 ~runtime_label
                 ~terminal_error
                 ~context
                 ~context_injector
                 ~tool_name:result.tool_name
                 ~input:result.input
                 ~content:result.content
                 ~outcome:result.outcome;
               { success =
                   not (Agent_sdk.Types.tool_result_outcome_is_error result.outcome)
               ; content = result.content
               }
             | Error error ->
               let detail = tool_hook_error_to_string error in
               (match error with
                | Agent_sdk.Agent_tools.Hook_execution_failed
                    { stage = (Post_tool_use | Post_tool_use_failure); _ } ->
                  record_terminal_error terminal_error detail;
                  { success = true
                  ; content = "Tool completed, but its post-execution hook failed; do not retry"
                  }
                | Agent_sdk.Agent_tools.Hook_execution_failed _ ->
                  { success = false; content = detail }))
        in
        match execute () with
        | result -> settle result
        | exception exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          Eio.Cancel.protect (fun () ->
            ignore
              (settle
                 { success = false
                 ; content = "dynamic tool call exited without an authoritative result"
                 }));
          Printexc.raise_with_backtrace exn backtrace)
  }
;;

let dynamic_tools ~runtime_label ~keeper_name ~turn_count ~tools ~hooks ~event_bus
    ~context_injector ~context ~terminal_error ~raw_trace_run =
  match tools, context with
  | [], _ -> Ok []
  | _ :: _, None ->
    Error
      (config_error
         ~field:"context"
         (runtime_label ^ " dynamic tools require the Keeper shared context"))
  | tools, Some context ->
    let next_dynamic_invocation_index = Atomic.make 0 in
    Ok
      (List.map
         (dynamic_tool_of_oas
            ~runtime_label
            ~keeper_name
            ~turn_count
            ~context
            ~tools
            ~hooks
            ~event_bus
            ~context_injector
            ~terminal_error
            ~raw_trace_run
            ~next_dynamic_invocation_index)
         tools)
;;
