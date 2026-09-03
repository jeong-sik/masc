open Result.Syntax

let config_error ~field detail =
  Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; detail })
;;

let internal_error detail = Agent_core.Error.Internal detail

type terminal_boundary_outcome = Runtime_official_client_tool.terminal_boundary_outcome =
  | Terminal_completed
  | Durable_stimulus_deferred
  | External_effect_deferred
  | Terminal_failed of
      { failure_class : Tool_result.tool_failure_class
      ; effect_disposition : Tool_result.failure_effect_disposition
      ; diagnostic : string
      }

type host_stop = Runtime_official_client_tool.host_stop =
  | Repeated_tool_call of
      { tool_name : string
      ; repeated_count : int
      }
  | Terminal_tool_boundary of
      { tool_name : string
      ; outcome : terminal_boundary_outcome
      }

type image_block =
  { media_type : string
  ; base64_data : string
  }

(* Split a goal into the text the CLI receives and the images that ride with it.
   [text_of_blocks] rejects every non-text block; this admits [Image] for the
   transports that carry one, and keeps rejecting the rest so a block nobody
   projects cannot slip through as silence. Only [Base64] images are carried:
   a [Url] or [File_id] source names bytes this process never read, and the CLI
   has no way to fetch them. *)
let text_and_images_of_blocks ~runtime_label ~field blocks =
  let rec loop texts images = function
    | [] -> Ok (String.concat "\n" (List.rev texts), List.rev images)
    | Agent_core.Types.Text text :: rest -> loop (text :: texts) images rest
    | Agent_core.Types.Image { media_type; data; source_type } :: rest ->
      (match source_type with
       | Agent_core.Types.Base64 ->
         loop texts ({ media_type; base64_data = data } :: images) rest
       | Agent_core.Types.Url | Agent_core.Types.File_id ->
         Error
           (config_error
              ~field
              (runtime_label ^ " image projection admits base64 sources only")))
    | _ :: _ ->
      Error
        (config_error
           ~field
           (runtime_label ^ " projection admits text and image blocks only"))
  in
  loop [] [] blocks
;;

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

let encode_history_message = Keeper_official_client_context_codec.encode

let user_message text : Agent_core.Types.message =
  { role = User
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

(* Official-client adapters own their provider instruction projection. Keep
   dynamic context on that System path rather than copying Agent Core's
   synthetic User-message encoding, while retaining the shared typed identity
   used by prompt attribution and input-window projection. *)
let extra_system_context_message text : Agent_core.Types.message =
  { role = System
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = Agent_core.Types.Extra_system_context_provenance.metadata
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

let invoke_turn_completion_hooks ~runtime_label ~keeper_name ~turn_count ~hooks
    (response : Agent_core.Types.api_response) =
  let* () =
    match
      invoke_turn_hook
        ~keeper_name
        ~turn_count
        ~hook_name:"after_turn"
        hooks.Agent_core.Hooks.after_turn
        (Agent_core.Hooks.AfterTurn
           { turn = turn_count; response; tool_source_map = None })
    with
    | Continue -> Ok ()
    | HookFailed { stage; detail } ->
      Error (hook_error ~runtime_label ~hook_name:"after_turn" ~stage detail)
    | decision ->
      Error (illegal_hook_decision ~runtime_label ~hook_name:"after_turn" decision)
  in
  match
    invoke_turn_hook
      ~keeper_name
      ~turn_count
      ~hook_name:"on_stop"
      hooks.on_stop
      (Agent_core.Hooks.OnStop { reason = response.stop_reason; response })
  with
  | Continue -> Ok ()
  | HookFailed { stage; detail } ->
    Error (hook_error ~runtime_label ~hook_name:"on_stop" ~stage detail)
  | decision ->
    Error (illegal_hook_decision ~runtime_label ~hook_name:"on_stop" decision)
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
     | Runtime_agent.Yielded_after_repeated_tool_call { turns_used; _ }
     | Runtime_agent.Yielded_after_repeated_assistant_text { turns_used; _ } ->
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

(* Snap a requested reasoning effort into the catalog's accepted set: the
   requested effort when it is accepted, otherwise the nearest accepted effort
   (highest below; lowest when every accepted effort is higher). The catalog
   ([models.toml] [accepted_reasoning_efforts]) is the SSOT, so an operator
   controls the effective effort by editing that row.

   Shared by the Codex and Claude Code lanes: before this lived here, the
   same operator-declared effort was clamped on Codex but failed the whole
   turn on Claude Code ([reasoning_args] rejects [Minimal]), so which lane a
   keeper ran on decided whether a config value was survivable. *)
let clamp_reasoning_effort_to_catalog
    ~(model_id : string option)
    ~(requested : Llm_provider.Reasoning_effort.t option)
    : Llm_provider.Reasoning_effort.t option =
  match requested, model_id with
  | None, _ | _, None -> requested
  | Some effort, Some model ->
    (match Llm_provider.Capabilities.for_model_id_catalog model with
     | None -> requested
     | Some caps ->
       (match caps.Llm_provider.Capabilities.accepted_reasoning_efforts with
        | None -> requested
        | Some accepted when List.mem effort accepted -> requested
        | Some [] -> requested
        | Some (first :: rest as accepted) ->
          let below =
            List.filter
              (fun candidate ->
                 Llm_provider.Reasoning_effort.compare candidate effort < 0)
              accepted
          in
          let pick_max a b =
            if Llm_provider.Reasoning_effort.compare a b >= 0 then a else b
          in
          let pick_min a b =
            if Llm_provider.Reasoning_effort.compare a b <= 0 then a else b
          in
          match below with
          | [] -> Some (List.fold_left pick_min first rest)
          | b_first :: b_rest -> Some (List.fold_left pick_max b_first b_rest)))
;;

let effective_reasoning_effort
    ~runtime_label ~keeper_name ~runtime_id ~model_id ~requested =
  let effective = clamp_reasoning_effort_to_catalog ~model_id ~requested in
  (match requested, effective with
   | Some asked, Some snapped
     when Llm_provider.Reasoning_effort.compare asked snapped <> 0 ->
     Log.Keeper.info
       ~keeper_name
       "%s reasoning effort clamped to catalog: model=%s asked=%s effective=%s"
       runtime_label
       (Option.value model_id ~default:runtime_id)
       (Llm_provider.Reasoning_effort.to_string asked)
       (Llm_provider.Reasoning_effort.to_string snapped)
   | _ -> ());
  effective
;;

let host_stop_result ~runtime_id ~model ~session_id ~turn_id ~turns_used ~latency_ms ~usage
    stop =
  match stop with
  | Terminal_tool_boundary
      { outcome = Terminal_failed { failure_class; effect_disposition; diagnostic }
      ; _
      } ->
    Error
      (Keeper_internal_error.core_error_of_masc_internal_error
         (Keeper_internal_error.Terminal_effect_failed
            { failure_class; effect_disposition; diagnostic }))
  | ( Repeated_tool_call _
    | Terminal_tool_boundary
        { outcome =
            ( Terminal_completed
            | Durable_stimulus_deferred
            | External_effect_deferred )
        ; _
        } ) ->
    let response : Agent_core.Types.api_response =
      { id = turn_id
      ; model
      ; stop_reason = Agent_core.Types.EndTurn
      ; content = []
      ; usage
      ; telemetry =
          Some
            { Agent_core.Types.default_inference_telemetry with
              canonical_model_id = Some model
            }
      }
    in
    let stop_reason =
      match stop with
      | Repeated_tool_call { tool_name; repeated_count } ->
        Runtime_agent.Yielded_after_repeated_tool_call
          { turns_used; tool_name; repeated_count }
      | Terminal_tool_boundary { outcome = Terminal_completed; _ } ->
        Runtime_agent.Completed
      | Terminal_tool_boundary { outcome = Durable_stimulus_deferred; _ } ->
        Runtime_agent.Yielded_to_durable_stimulus { turns_used }
      | Terminal_tool_boundary { outcome = External_effect_deferred; _ } ->
        Runtime_agent.Awaiting_external_effect { turns_used }
      | Terminal_tool_boundary { outcome = Terminal_failed _; _ } -> assert false
    in
    (* masc#31312: this host-stop path was the one producer that returned
       [runtime_observation = None] on a successful or yielded turn, so every
       tool-boundary stop (completed, deferred stimulus, external effect,
       repeated tool call) reached the execution receipt as
       [Runtime_not_observed] and the operator disposition fell to
       "unmapped_runtime_state". The vendor loop ran exactly one attempt to
       get here, so record that attempt the same way the in-loop terminal
       does. *)
    let capture, _metrics = Runtime_observation.runtime_metrics_for_candidates () in
    Runtime_observation.record_attempt_terminal
      capture
      ~model_id:model
      ~latency_ms
      ~error:None;
    let runtime_observation =
      Runtime_observation.runtime_observation_with_metrics
        ~runtime_id
        ~selected_model_raw:(Some model)
        ~capture
        ~attempt_details_source:"official_client_host_stop"
        ~agent_core_internal_runtime_allowed:false
        ~usage_scope:
          (match usage with
           | Some _ -> Runtime_usage_scope.Per_request
           | None -> Runtime_usage_scope.Usage_scope_unavailable)
        ()
    in
    Ok
      { Runtime_agent.response
      ; checkpoint = None
      ; session_id
      ; session_resumed = None
      ; turns = turns_used
      ; trace_ref = None
      ; run_validation = None
      ; runtime_observation = Some runtime_observation
      ; stop_reason
      }
;;

type prepared_turn =
  { messages : Agent_core.Types.message list
  ; system_prompt : string
  ; tools : Agent_core.Tool.t list
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

(* Measure the shared, content-dependent envelope. Each adapter may add a fixed
   role prefix or protocol framing around it. *)
let measure_message_bytes message = String.length (encode_history_message message)
;;

let prepare_turn ~runtime_label ~keeper_name ~turn_count ~system_prompt ~tools
    ~initial_messages ~model_input_projection ~hooks ~configured_reasoning_effort
    =
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
    | Some text -> messages @ [ extra_system_context_message text ]
  in
  let* messages =
    match model_input_projection with
    | None -> Ok messages
    | Some project ->
      (try
         (* The projection names its own failure. Wrapping it as
            [InvalidConfig { field = "model_input_projection" }] renamed a
            per-candidate capacity bound into a request defect, and no reader
            of that field ever existed. *)
         project messages
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
  (* No preemptive cut of the seed. The provider owns its own window and says
     so in a typed terminal — glm code 1261, Codex "Context overflow" — which
     [Keeper_turn_driver_try_provider.context_overflow_shrink_sequence] already
     consumes to shrink and retry, starting from
     [unbounded_model_input_capacity_bytes]. Cutting here as well meant two
     authorities over the same window, and the one that ran first measured in
     wire bytes rather than tokens and discarded the oldest atoms outright.

     The discard was the part that could not be justified: it removed
     conversation the keeper had already committed to, kept no copy, and its
     [seed_dropped_atoms] receipt had no reader anywhere in the tree — the loss
     was reported to nobody. Reactive shrink loses nothing the provider has not
     already refused to accept. *)
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
    }
;;

type dynamic_tool_result = Runtime_official_client_tool.dynamic_tool_result =
  { success : bool
  ; content : string
  ; abort_turn : host_stop option
  }

type dynamic_tool = Runtime_official_client_tool.dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

(* One pre_tool_use rejection the model must be able to repair from
   (masc#28885). The official-client CLI owns the live conversation, so
   when it escalates the reject to a dead turn, this record is the only
   surviving typed copy of the round-trip masc produced. *)
type rejected_tool_call =
  { call_id : string
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; detail : string
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

type repeated_call_state =
  { fingerprint : string
  ; count : int
  }

(* One exact retry may be deliberate; the third identical outcome proves two
   consecutive transitions made no progress, matching the Agent Core guard. *)
let repeated_call_abort_threshold = 3

let dynamic_tool_fingerprint ~tool_name ~input result =
  let open Digestif.SHA256 in
  let context = feed_string empty tool_name in
  let context = feed_string context (input |> Yojson.Safe.sort |> Yojson.Safe.to_string) in
  let context = feed_string context (if result.success then "success" else "failure") in
  let context = feed_string context result.content in
  get context |> to_hex
;;

let rec observe_repeated_call state fingerprint =
  let before = Atomic.get state in
  let after =
    match before with
    | Some previous when String.equal previous.fingerprint fingerprint ->
      { fingerprint; count = previous.count + 1 }
    | Some _ | None -> { fingerprint; count = 1 }
  in
  if Atomic.compare_and_set state before (Some after)
  then after.count
  else observe_repeated_call state fingerprint
;;

type raw_trace_stage =
  | Run_start
  | Assistant_block
  | Tool_start
  | Tool_finish
  | Native_tool_start
  | Native_tool_finish
  | Run_finish

let raw_trace_stage_label = function
  | Run_start -> "run_start"
  | Assistant_block -> "assistant_block"
  | Tool_start -> "tool_start"
  | Tool_finish -> "tool_finish"
  | Native_tool_start -> "native_tool_start"
  | Native_tool_finish -> "native_tool_finish"
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
             |> String_util.trim_nonempty)
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

let record_raw_native_tool ~keeper_name ~raw_trace_run ~phase observation =
  match raw_trace_run with
  | None -> ()
  | Some active ->
    let stage, record =
      match phase with
      | `Started ->
        Native_tool_start,
        Agent_core.Raw_trace.record_native_tool_started
      | `Finished ->
        Native_tool_finish,
        Agent_core.Raw_trace.record_native_tool_finished
    in
    let identity =
      match observation.Runtime_native_tools.identity with
      | Some (Runtime_native_tools.Call_id call_id) ->
        Some (Agent_core.Raw_trace.Call_id call_id)
      | Some (Runtime_native_tools.Provider_step { conversation_id; step_index }) ->
        Some (Agent_core.Raw_trace.Provider_step { conversation_id; step_index })
      | None -> None
    in
    let origin =
      match observation.origin with
      | Runtime_native_tools.Built_in -> Agent_core.Raw_trace.Built_in
      | Runtime_native_tools.Mcp_wrapper -> Agent_core.Raw_trace.Mcp_wrapper
    in
    ignore
      (observe_raw_trace ~keeper_name ~stage (fun () ->
         record
           active
           ~identity
           ~origin
           ~tool_name:observation.tool_name))
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

let dynamic_tool_of_agent_core ~tool_approval ~runtime_label ~keeper_name
    ~turn_count ~context ~tools
    ~(hooks : Agent_core.Hooks.hooks) ~event_bus ~context_injector
    ~terminal_effect_state ~terminal_error ~pre_tool_rejects ~raw_trace_run
    ~next_dynamic_invocation_index ~repeated_call_state ~on_result_handoff
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
          ; execution_mode = Agent_core.Tool.execution_mode tool ~input
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
          (* Settled by the same gate AGENT_CORE's own tool loop uses, so one
             pre_tool_use decision cannot mean two different things depending
             on which runtime the keeper is bound to. This host used to decide
             it here, and disagreed in two places: a failed hook came back as
             an ordinary tool failure rather than a turn-level reject, and
             ElicitToolApproval was refused outright instead of being offered
             to a caller-supplied approval callback. *)
          let settlement =
            Agent_core.Agent_tool_pre_execution_gate.settle
              ?tool_approval
              ~event_bus
              ~agent_name:keeper_name
              ~invocation
              ~tool_name:tool.schema.name
              ~input
              pre_tool_use
          in
          match settlement with
          | Agent_core.Agent_tool_pre_execution_gate.Block detail ->
            (* The corrective error result goes back to the CLI, and the
               same round-trip is kept here so a CLI that kills the turn
               instead of retrying cannot erase it (masc#28885). *)
            pre_tool_rejects
            := { call_id; tool_name = tool.schema.name; input; detail }
               :: !pre_tool_rejects;
            { success = false; content = detail; abort_turn = None }
          | Agent_core.Agent_tool_pre_execution_gate.Reject { stage; detail } ->
            (* A hook that failed, or a decision illegal at this stage. Both
               are turn-level faults rather than something the model can
               repair, so the terminal error records why the turn stopped. *)
            let detail =
              Printf.sprintf
                "%s pre_tool_use rejected at %s: %s"
                runtime_label
                (Agent_core.Hooks.hook_stage_to_string stage)
                detail
            in
            record_terminal_error terminal_error detail;
            { success = false; content = detail; abort_turn = None }
          | Agent_core.Agent_tool_pre_execution_gate.Admit ->
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
               ; abort_turn = None
               }
             | Error error ->
               let detail = tool_hook_error_to_string error in
               (match error with
                | Agent_core.Agent_tools.Hook_execution_failed
                    { stage = (Post_tool_use | Post_tool_use_failure); _ } ->
                  record_terminal_error terminal_error detail;
                  { success = true
                  ; content =
                      Tool_guidance.to_string Tool_guidance.Post_execution_hook_failed
                  ; abort_turn = None
                  }
                | Agent_core.Agent_tools.Hook_execution_failed _ ->
                  { success = false; content = detail; abort_turn = None }))
        in
        match execute () with
        | result ->
          let result = settle result in
          let terminal_boundary =
            match terminal_effect_state () with
            | Keeper_tools_agent_core.Terminal_effect_failed
                ({ effect_disposition =
                     ( Tool_result.Proven_post_effect
                     | Tool_result.Effect_outcome_unknown )
                 ; _
                 } as failure) ->
              (* A composition may be statically ordinary yet fail after a
                 nested effect.  Producer-owned aggregate evidence outranks
                 the outer success-completion declaration: allowing the
                 provider to retry would repeat an already-applied or
                 indeterminate effect. *)
              Some
                (Terminal_tool_boundary
                   { tool_name = tool.schema.name
                   ; outcome =
                       Terminal_failed
                         { failure_class = failure.failure_class
                         ; effect_disposition = failure.effect_disposition
                         ; diagnostic = failure.diagnostic
                         }
                   })
            | ( Keeper_tools_agent_core.Terminal_effect_open
              | Keeper_tools_agent_core.Deferred_tool_result
              | Keeper_tools_agent_core.External_effect_deferred
              | Keeper_tools_agent_core.Terminal_effect_completed _
              | Keeper_tools_agent_core.Terminal_effect_failed
                  { effect_disposition = Tool_result.Proven_pre_effect; _ } ) as state ->
              (match Agent_core.Tool.completion tool with
               | Agent_core.Tool_contract.Continue_after_success -> None
               | Agent_core.Tool_contract.Terminal_after_success _ ->
                 (match state with
               | Keeper_tools_agent_core.Terminal_effect_completed _
                 ->
                 Some
                   (Terminal_tool_boundary
                      { tool_name = tool.schema.name
                      ; outcome = Terminal_completed
                      })
               (* A Gate deferral parks one call and nothing has happened
                  yet, so a terminal tool is no exception: the turn keeps
                  going and the host replays the call once the approval
                  resolves. See Keeper_tool_terminal_boundary, which makes
                  the same decision for the native loop. *)
               | Keeper_tools_agent_core.External_effect_deferred -> None
               | Keeper_tools_agent_core.Deferred_tool_result ->
                 Some
                   (Terminal_tool_boundary
                      { tool_name = tool.schema.name
                      ; outcome = Durable_stimulus_deferred
                      })
               | Keeper_tools_agent_core.Terminal_effect_failed
                   { effect_disposition = Tool_result.Proven_pre_effect; _ }
               | Keeper_tools_agent_core.Terminal_effect_open ->
                 None
               | Keeper_tools_agent_core.Terminal_effect_failed
                   { effect_disposition =
                       ( Tool_result.Proven_post_effect
                       | Tool_result.Effect_outcome_unknown )
                   ; _
                   } ->
                 assert false))
          in
          let result =
            match terminal_boundary with
            | Some
                (Terminal_tool_boundary
                  { outcome = Terminal_failed _; _ } as abort_turn) ->
              { result with success = false; abort_turn = Some abort_turn }
            | Some abort_turn -> { result with abort_turn = Some abort_turn }
            | None -> result
          in
          let fingerprint =
            dynamic_tool_fingerprint ~tool_name:tool.schema.name ~input result
          in
          let repeated_count = observe_repeated_call repeated_call_state fingerprint in
          let final_result =
            if repeated_count < repeated_call_abort_threshold
            then result
            else
            let detail =
              Printf.sprintf
                "repeated exact dynamic tool call detected: tool=%s count=%d"
                tool.schema.name
                repeated_count
            in
            Log.Keeper.warn ~keeper_name "%s" detail;
              { result with
                abort_turn =
                  Some
                    (Repeated_tool_call
                       { tool_name = tool.schema.name; repeated_count })
              }
          in
          (try on_result_handoff ~invocation ~content:final_result.content with
           | exn ->
             Llm_provider.Reserved_exn.reraise_if_reserved exn;
             Log.Keeper.warn
               ~keeper_name
               "official-client result handoff observation failed: tool=%s call_id=%s error=%s"
               tool.schema.name
               (Agent_core.Tool_contract.Invocation.tool_use_id invocation)
               (Printexc.to_string exn));
          final_result
        | exception exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          Eio.Cancel.protect (fun () ->
            ignore
              (settle
                 { success = false
                 ; content = "dynamic tool call exited without an authoritative result"
                 ; abort_turn = None
                 }));
          Printexc.raise_with_backtrace exn backtrace)
  }
;;

let dynamic_tools ~tool_approval ~runtime_label ~keeper_name ~turn_count ~tools
    ~hooks ~event_bus ~context_injector ~context ~terminal_effect_state
    ~terminal_error ~pre_tool_rejects
    ?(on_result_handoff = fun ~invocation:_ ~content:_ -> ()) ~raw_trace_run () =
  match tools, context with
  | [], _ -> Ok []
  | _ :: _, None ->
    Error
      (config_error
         ~field:"context"
         (runtime_label ^ " dynamic tools require the Keeper shared context"))
  | tools, Some context ->
    let next_dynamic_invocation_index = Atomic.make 0 in
    let repeated_call_state = Atomic.make None in
    Ok
      (List.map
         (dynamic_tool_of_agent_core
            ~tool_approval
            ~runtime_label
            ~keeper_name
            ~turn_count
            ~context
            ~tools
            ~hooks
            ~event_bus
            ~context_injector
            ~terminal_effect_state
            ~terminal_error
            ~pre_tool_rejects
            ~raw_trace_run
            ~next_dynamic_invocation_index
            ~repeated_call_state
            ~on_result_handoff)
         tools)
;;

(* Append the reject round-trips of a dead turn to the canonical
   checkpoint so the next turn's replay carries the corrective text
   (masc#28885: 14,466 persisted messages held exactly one reject
   round-trip — the one from a turn that survived; every escalated turn
   lost its correction and the model resent the same broken call).
   Message shape mirrors what a surviving turn persists byte-for-byte:
   an assistant [ToolUse] block answered by a tool-role [ToolResult]
   whose outcome is the deterministic validation failure. A missing
   checkpoint means no replay exists to correct — skipped, not an
   error. Rejects are recorded newest-first; the append restores call
   order. *)
let persist_pre_tool_rejects ~session_dir ~session_id rejects =
  match rejects with
  | [] -> Ok 0
  | rejects ->
    (match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id with
     | Error Keeper_checkpoint_store.Not_found -> Ok 0
     | Error error ->
       Error
         (Printf.sprintf
            "reject round-trip persistence could not load the checkpoint: %s"
            (match error with
             | Keeper_checkpoint_store.Not_found -> "not found"
             | Keeper_checkpoint_store.Store_error detail
             | Keeper_checkpoint_store.Parse_error detail
             | Keeper_checkpoint_store.Io_error detail
             | Keeper_checkpoint_store.Agent_core_error detail -> detail))
     | Ok checkpoint ->
       let roundtrip { call_id; tool_name; input; detail } =
         [ { Agent_core.Types.role = Agent_core.Types.Assistant
           ; content =
               [ Agent_core.Types.ToolUse { id = call_id; name = tool_name; input } ]
           ; name = None
           ; tool_call_id = None
           ; metadata = []
           }
         ; { Agent_core.Types.role = Agent_core.Types.Tool
           ; content =
               [ Agent_core.Types.ToolResult
                   { tool_use_id = call_id
                   ; content = detail
                   ; outcome =
                       Agent_core.Types.Tool_failed
                         { failure_kind = Agent_core.Types.Validation_error
                         ; error_class = Some Agent_core.Types.Deterministic
                         }
                   ; json = None
                   ; content_blocks = None
                   }
               ]
           ; name = None
           ; tool_call_id = Some call_id
           ; metadata = []
           }
         ]
       in
       let appended = List.concat_map roundtrip (List.rev rejects) in
       let checkpoint =
         { checkpoint with
           Agent_core.Checkpoint.messages = checkpoint.messages @ appended
         }
       in
       (match
          Keeper_checkpoint_store.save_agent_core_classified ~session_dir checkpoint
        with
        | Ok _ -> Ok (List.length rejects)
        | Error detail -> Error detail))
;;



let admit_native_posture ~posture ~approval_mode ~none_supported ~client_label =
  match (posture : Runtime_native_tools.posture), none_supported with
  | Native_none, false ->
    Error
      (Printf.sprintf
         "%s cannot disable its built-in tools; declare native = \"read\" or \
          \"full\""
         client_label)
  | Native_full, _ ->
    (match (approval_mode : Keeper_tool_approval_mode.mode) with
     | Yolo -> Ok ()
     | Auto ->
       Error
         (Printf.sprintf
            "native = \"full\" runs %s built-in effects outside the approval \
             gate; set the keeper's tool-approval mode to yolo first"
            client_label))
  | Native_none, true | Native_read, _ -> Ok ()
;;

(* RFC-0390 admission review (P0): an admission refusal must not kill the
   runtime call — the keeper would lose every turn until an operator flips
   an in-memory approval mode after each restart. [admit_native_posture]
   stays a pure typed predicate (tests pin its refusals); the resolver
   below is the policy point: a posture admission cannot honor degrades
   to the safest weaker posture and the downgrade is recorded as a typed
   event, never silent. Profile load failures remain fail-closed — that
   is a declaration-time error, not an admission-time one. *)
(* #30408 review: the two refusal branches of [admit_native_posture] have
   different lifetimes and must not share one reporting cadence.

   [full] under a non-yolo approval mode is TURN state — the mode lives in
   process memory, reverts to Auto on restart, and can be flipped mid-run,
   so every affected turn says so (that per-turn event is the P0 fix).

   [none] on a client without a disable switch is a STATIC contradiction:
   the profile TOML declares [none] while runtime.toml (the assignment
   SSOT) put this keeper on a client that cannot honor it. Nothing about
   it changes turn to turn, so repeating the event every turn is noise.
   It is reported once per process per (keeper, client) pair, at the
   first posture resolution after boot — the earliest moment both sides
   of the contradiction coexist, since [keeper_turn_up_create] writes
   the profile after the assignment exists. The gate clears when a later
   resolution honors the declaration (operator fixed the profile or the
   assignment), so a re-introduced contradiction is reported again. *)
let native_posture_static_contradiction_gate : (string, unit) Hashtbl.t =
  Hashtbl.create 16
;;

let resolve_native_posture ~base_path ~keeper_name ~client_label ~default
    ~none_supported =
  match
    Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
      ~base_path
      keeper_name
  with
  | Error load_error ->
    Error
      (config_error
         ~field:"keeper.tools.native"
         (Keeper_types_profile.keeper_toml_load_error_to_string load_error))
  | Ok defaults ->
    let declared = Option.value defaults.native_tool_posture ~default in
    let approval_mode =
      Keeper_tool_approval_mode.resolve
        (Keeper_tool_approval_mode.shared ())
        ~keeper_name
    in
    let static_contradiction_key = keeper_name ^ "\000" ^ client_label in
    (match
       admit_native_posture ~posture:declared ~approval_mode ~none_supported
         ~client_label
     with
     | Ok () ->
       (* The declaration is honored: any earlier static contradiction for
          this pair is resolved, so a future re-contradiction reports
          again instead of being swallowed by the gate. *)
       Hashtbl.remove
         native_posture_static_contradiction_gate
         static_contradiction_key;
       Ok declared
     | Error detail ->
       let effective =
         Runtime_native_tools.degrade_on_admission
           ~posture:declared
           ~none_supported
           ()
       in
       let static_contradiction =
         (declared : Runtime_native_tools.posture) = Native_none
         && not none_supported
       in
       if static_contradiction then (
         if
           not
             (Hashtbl.mem
                native_posture_static_contradiction_gate
                static_contradiction_key)
         then (
           Hashtbl.replace
             native_posture_static_contradiction_gate
             static_contradiction_key
             ();
           Log.Keeper.warn
             "%s: static native-posture contradiction (reported once per \
              boot, not per turn): profile declares native = \"none\" but %s \
              cannot disable its built-in tools; the lane runs at its \
              \"read\" floor until the profile or the runtime.toml \
              assignment changes"
             keeper_name client_label;
           Keeper_event_publisher.publish_native_posture_degraded
             ~keeper_name
             ~client_label
             ~declared:(Runtime_native_tools.to_string declared)
             ~effective:(Runtime_native_tools.to_string effective)
             ~reason:detail))
       else
         (* Turn-scoped degradation ([full] under a non-yolo approval
            mode): the condition can appear and disappear with the
            approval mode, so it stays per-turn. *)
         Keeper_event_publisher.publish_native_posture_degraded
           ~keeper_name
           ~client_label
           ~declared:(Runtime_native_tools.to_string declared)
           ~effective:(Runtime_native_tools.to_string effective)
           ~reason:detail;
       Ok effective)
;;
