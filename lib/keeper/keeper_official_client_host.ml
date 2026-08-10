open Result.Syntax

let config_error ~field detail =
  Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; detail })
;;

let internal_error detail = Agent_core.Error.Internal detail

let text_of_blocks ~runtime_label ~field blocks =
  let rec loop texts = function
    | [] -> Ok (String.concat "\n" (List.rev texts))
    | Agent_core.Types.Text text :: rest -> loop (text :: texts) rest
    | _ :: _ ->
      Error
        (config_error
           ~field
           (runtime_label ^ " official-client projection admits text blocks only"))
  in
  loop [] blocks
;;

let encode_history_message (message : Agent_core.Types.message) =
  let text_only =
    message.role <> Tool
    && List.for_all
         (function
           | Agent_core.Types.Text _ -> true
           | _ -> false)
         message.content
  in
  if text_only
  then
    message.content
    |> List.filter_map (function
      | Agent_core.Types.Text text -> Some text
      | _ -> None)
    |> String.concat "\n"
  else
    `Assoc
      [ "schema", `String "masc.official-client-context-message.v1"
      ; "message", Keeper_context_core.message_to_json message
      ]
    |> Yojson.Safe.to_string
;;

let user_message text : Agent_core.Types.message =
  { role = User
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let system_message text : Agent_core.Types.message =
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
  |> List.find_map (fun (message : Agent_core.Types.message) ->
    match message.role with
    | Tool ->
      Some
        (List.filter_map
           (function
             | Agent_core.Types.ToolResult { content; outcome; _ } ->
               Some (Agent_core.Types.tool_result_of_outcome ~content outcome)
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
       (Agent_core.Hooks.hook_stage_to_string stage)
       detail)
;;

let illegal_hook_decision ~runtime_label ~hook_name decision =
  config_error
    ~field:"hooks"
    (Printf.sprintf
       "%s runtime %s hook returned unsupported decision %s"
       runtime_label
       hook_name
       (Agent_core.Hooks.decision_kind_to_string
          (Agent_core.Hooks.classify_decision decision)))
;;

let invoke_turn_hook ~keeper_name ~turn_count ~hook_name hook event =
  Agent_core.Agent_tools.invoke_hook
    ~tracer:Agent_core.Tracing.null
    ~agent_name:keeper_name
    ~turn_count
    ~hook_name
    hook
    event
;;

let lifecycle_outcome = function
  | Error error -> Agent_core.Agent_lifecycle_events.Failed error
  | Ok ({ response; stop_reason; _ } : Runtime_agent.run_result) ->
    (match stop_reason with
     | Runtime_agent.Completed ->
       Agent_core.Agent_lifecycle_events.Completed response
     | Runtime_agent.InputRequired { request; _ } ->
       Agent_core.Agent_lifecycle_events.Input_required request
     | Runtime_agent.Yielded_to_operation_queued { turns_used }
     | Runtime_agent.Yielded_to_durable_stimulus { turns_used }
     | Runtime_agent.Awaiting_external_effect { turns_used }
     | Runtime_agent.Yielded_after_repeated_tool_call { turns_used; _ } ->
       Agent_core.Agent_lifecycle_events.Yielded { turn = turns_used })
;;

let with_run_lifecycle_events ~event_bus ~keeper_name run =
  Agent_core.Agent_lifecycle_events.with_run_lifecycle_events
    ~event_bus
    ~agent_name:keeper_name
    ~raw_trace:None
    ~current_run_id:(fun () -> None)
    ~classify:lifecycle_outcome
    run
;;

type prepared_turn =
  { messages : Agent_core.Types.message list
  ; system_prompt : string
  ; tools : Agent_core.Tool.t list
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  ; seed_dropped_atoms : int
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

(* The canonical MASC message encoder, the same one the Agent_core budget path
   measures with. It is not any adapter's own rendering: antigravity renders
   "ROLE:\ntext" and the JSON form of that message is strictly larger, so the
   measure is at or above what each adapter actually sends and the ceiling
   cannot be exceeded by measuring here. *)
let measure_message_bytes (message : Agent_core.Types.message) =
  String.length
    (Yojson.Safe.to_string (Keeper_context_core.message_to_json message))
;;

let prepare_turn ~runtime_label ~keeper_name ~turn_count ~system_prompt ~tools
    ~initial_messages ~model_input_projection ~hooks ~configured_reasoning_effort
    ~max_prompt_bytes =
  let hooks = match hooks with Some hooks -> hooks | None -> Agent_core.Hooks.empty in
  let before_turn =
    invoke_turn_hook
      ~keeper_name
      ~turn_count
      ~hook_name:"before_turn"
      hooks.before_turn
      (Agent_core.Hooks.BeforeTurn { turn = turn_count; messages = initial_messages })
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
  (* Seed the params the hook sees rather than overwriting its answer: an
     operator declaration is a default for the turn, not an override of a
     hook that deliberately chose a different effort. *)
  let current_params =
    match configured_reasoning_effort with
    | None -> Agent_core.Hooks.default_turn_params
    | Some _ ->
      { Agent_core.Hooks.default_turn_params with
        reasoning_effort = configured_reasoning_effort
      }
  in
  let before_turn_params =
    invoke_turn_hook
      ~keeper_name
      ~turn_count
      ~hook_name:"before_turn_params"
      hooks.before_turn_params
      (Agent_core.Hooks.BeforeTurnParams
         { turn = turn_count
         ; messages
         ; last_tool_results = last_tool_results messages
         ; current_params
         ; reasoning = Agent_core.Hooks.empty_reasoning_summary
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
  (* An official-client turn 1 seeds the vendor conversation with the whole
     projected history; from turn 2 the client owns the transcript and the
     adapters send only the goal. So an unbounded seed does not fail once — it
     fails on turn 1, never reaches turn 2, and re-renders a larger history on
     the next cycle. Recovery closes the loop rather than breaking it: a fresh
     session resets the counter, which makes the next turn a start turn again.
     Measured on the live fleet with three keepers pinned at turn_count = 1,
     one of them auto-superseding to a fresh session 293 times in a single log.

     The newest messages are kept, since the goal answers the most recent turn
     and trimming the tail would drop exactly the context it refers to.
     [dropped_atoms] is returned to the caller rather than logged here so the
     loss lands on the keeper's own line; a silent window would read as "the
     model saw everything".

     Applied here rather than in each adapter because all three consume
     [messages] for the same purpose and would otherwise carry three copies of
     one rule. Resume paths ignore [messages] entirely, so windowing is a no-op
     for them. *)
  let* messages, seed_dropped_atoms =
    match max_prompt_bytes with
    | None -> Ok (messages, 0)
    | Some capacity_bytes ->
      let reserved_bytes = String.length system_prompt in
      (match
         Runtime_model_input_tail_window.project_with_drop
           ~measure_message_bytes
           ~capacity_bytes
           ~reserved_bytes
           messages
       with
       | Ok projection ->
         let dropped = projection.Runtime_model_input_tail_window.dropped_atoms in
         if dropped > 0
         then
           Log.Keeper.warn
             "%s: %s start-turn seed dropped %d oldest message atom(s) to fit               the declared %d-byte prompt budget"
             keeper_name
             runtime_label
             dropped
             capacity_bytes;
         Ok (projection.Runtime_model_input_tail_window.messages, dropped)
       | Error error ->
         Error
           (config_error
              ~field:"max_prompt_bytes"
              (runtime_label
               ^ " start-turn seed does not fit the declared prompt budget: "
               ^ Runtime_model_input_tail_window.budget_error_to_string error)))
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
                 (Agent_core.Types.tool_choice_to_json choice))))
  in
  Ok
    { messages
    ; system_prompt
    ; tools
    ; reasoning_effort
    ; seed_dropped_atoms
    }
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
  | Agent_core.Agent_tools.Hook_execution_failed
      { hook_name; stage; tool_name; detail; _ } ->
    Printf.sprintf
      "%s hook failed at %s for tool %s: %s"
      hook_name
      (Agent_core.Hooks.hook_stage_to_string stage)
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
    | exn -> Error (Agent_core.Error.Internal (Printexc.to_string exn))
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
      (Agent_core.Error.to_string error);
    None
;;

let start_raw_trace ~keeper_name ~raw_trace ~prompt ?model ?reasoning_effort () =
  match raw_trace with
  | None -> None
  | Some sink ->
    observe_raw_trace ~keeper_name ~stage:Run_start (fun () ->
      Agent_core.Raw_trace.start_run
        sink
        ~agent_name:keeper_name
        ~prompt
        ?model
        ?reasoning_effort
        ())
;;

let finish_raw_error ~keeper_name raw_trace_run error =
  match raw_trace_run with
  | None -> ()
  | Some active ->
    ignore
      (observe_raw_trace ~keeper_name ~stage:Run_finish (fun () ->
         Agent_core.Raw_trace.finish_run
           active
           ~final_text:None
           ~stop_reason:None
           ~error:(Some (Agent_core.Error.to_string error))))
;;

let finish_raw_success ~keeper_name raw_trace_run (result : Runtime_agent.run_result) =
  match raw_trace_run with
  | None -> result
  | Some active ->
    let all_blocks_recorded = ref true in
    result.response.content
    |> List.iteri (fun block_index block ->
      if
        Option.is_none
          (observe_raw_trace ~keeper_name ~stage:Assistant_block (fun () ->
             Agent_core.Raw_trace.record_assistant_block active ~block_index block))
      then all_blocks_recorded := false);
    let finished =
      observe_raw_trace ~keeper_name ~stage:Run_finish (fun () ->
        Agent_core.Raw_trace.finish_run
          active
          ~final_text:
            (Agent_core.Types.text_of_response result.response
             |> String_util.trim_to_option)
          ~stop_reason:
            (Some
               (Agent_core.Types.stop_reason_to_string
                  result.response.stop_reason))
          ~error:None)
    in
    (match !all_blocks_recorded, finished with
     | true, Some trace_ref -> { result with trace_ref = Some trace_ref }
     | false, _ | _, None -> result)
;;

let record_raw_tool_started ~keeper_name ~raw_trace_run ~invocation ~tool_name ~input =
  match raw_trace_run with
  | None -> false
  | Some active ->
    Option.is_some
      (observe_raw_trace ~keeper_name ~stage:Tool_start (fun () ->
         Agent_core.Raw_trace.record_tool_execution_started
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
         Agent_core.Raw_trace.record_tool_execution_finished
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
    let output = Agent_core.Types.tool_result_of_outcome ~content outcome in
    (try
       match inject ~tool_name ~input ~output with
       | None -> ()
       | Some (injection : Agent_core.Hooks.injection) ->
         List.iter
           (fun (key, value) -> Agent_core.Context.set context key value)
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

let dynamic_tool_of_agent_core ~runtime_label ~keeper_name ~turn_count ~context ~tools
    ~(hooks : Agent_core.Hooks.hooks) ~event_bus ~context_injector ~terminal_error
    ~raw_trace_run ~next_dynamic_invocation_index
    (tool : Agent_core.Tool.t) =
  { name = tool.schema.name
  ; description = tool.schema.description
  ; input_schema = Agent_core.Types.params_to_input_schema tool.schema.parameters
  ; call =
      (fun ~call_id input ->
        let schedule : Agent_core.Tool_contract.schedule =
          { planned_index = Atomic.fetch_and_add next_dynamic_invocation_index 1
          ; batch_index = 0
          ; batch_size = 1
          ; execution_mode = Agent_core.Tool.execution_mode tool
          }
        in
        let invocation =
          Agent_core.Tool_contract.Invocation.create
            ~tool_use_id:call_id
            ~turn:turn_count
            ~schedule
            ~completion:(Agent_core.Tool.completion tool)
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
              (Agent_core.Hooks.PreToolUse
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
                (Agent_core.Hooks.hook_stage_to_string stage)
                detail
            in
            { success = false; content = detail }
          | (ElicitToolApproval _ | ElicitInput _) as decision ->
            let detail =
              Printf.sprintf
                "%s dynamic tool cannot settle hook decision %s without a host approval callback"
                runtime_label
                (Agent_core.Hooks.decision_kind_to_string
                   (Agent_core.Hooks.classify_decision decision))
            in
            record_terminal_error terminal_error detail;
            { success = false; content = detail }
          | (AdjustParams _ | Nudge _) as decision ->
            let detail =
              Printf.sprintf
                "%s dynamic tool received illegal pre_tool_use decision %s"
                runtime_label
                (Agent_core.Hooks.decision_kind_to_string
                   (Agent_core.Hooks.classify_decision decision))
            in
            record_terminal_error terminal_error detail;
            { success = false; content = detail }
          | Continue ->
            (match
               Agent_core.Agent_tools.find_and_execute_tool
                 ~context
                 ~tools
                 ~hooks
                 ~event_bus
                 ~tracer:Agent_core.Tracing.null
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
                   not (Agent_core.Types.tool_result_outcome_is_error result.outcome)
               ; content = result.content
               }
             | Error error ->
               let detail = tool_hook_error_to_string error in
               (match error with
                | Agent_core.Agent_tools.Hook_execution_failed
                    { stage = (Post_tool_use | Post_tool_use_failure); _ } ->
                  record_terminal_error terminal_error detail;
                  { success = true
                  ; content = "Tool completed, but its post-execution hook failed; do not retry"
                  }
                | Agent_core.Agent_tools.Hook_execution_failed _ ->
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
         (dynamic_tool_of_agent_core
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
