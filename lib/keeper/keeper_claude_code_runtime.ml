open Result.Syntax

let config_error = Keeper_official_client_host.config_error
let internal_error = Keeper_official_client_host.internal_error

module Host = Keeper_official_client_host
module Session_store = Keeper_official_client_session_store

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; effect_disposition : Keeper_provider_attempt_effect.t
  }

let runtime_label = "Claude Code"

let host_stop_turn_identity ~session_id ~turn_count =
  Printf.sprintf "%s:host-stop:%d" session_id turn_count
;;

let bounded_probe_config ~fallback_timeout_s
  (config : Runtime_claude_code.config)
  =
  match config.timeout_s with
  | Some _ -> config
  | None -> { config with timeout_s = Some fallback_timeout_s }
;;

module For_testing = struct
  let bounded_probe_config = bounded_probe_config
  let host_stop_turn_identity = host_stop_turn_identity
end

let project_messages messages =
  let rec loop system history = function
    | [] -> Ok (List.rev system, List.rev history)
    | (message : Agent_core.Types.message) :: rest ->
      (match message.role with
       | Agent_core.Types.System ->
         loop (Host.encode_history_message message :: system) history rest
       | Agent_core.Types.User | Agent_core.Types.Assistant | Agent_core.Types.Tool ->
         loop
           system
           (Keeper_official_client_context_codec.to_json message :: history)
           rest)
  in
  loop [] [] messages
;;

let initial_turn_prompt ~history ~goal =
  match history with
  | [] -> goal
  | _ :: _ ->
    `Assoc
      [ "schema", `String "masc.claude-code.initial-turn.v1"
      ; ( "history"
        , `List history )
      ; "current_goal", `String goal
      ]
    |> Yojson.Safe.to_string
;;

let unbounded_model_input_capacity_bytes = max_int

let measure_model_input_message_bytes message =
  String.length (Host.encode_history_message message)
;;

(* Keep the durable conversation intact and narrow only the provider-bound
   start seed after Claude has explicitly rejected the prior view as too
   large. The next structural boundary is computed before source projections
   append synthetic evidence, matching the Codex official-client path. *)
let model_input_projection_for_capacity
    ~capacity_bytes
    ~observed_next_shrink_capacity_bytes
    ~observed_floor_capacity_bytes
    source_projection
    messages =
  let windowed =
    if capacity_bytes = unbounded_model_input_capacity_bytes
    then Ok messages
    else
      Domain_pool_ref.submit_cpu_or_inline (fun () ->
        match
          Runtime_model_input_tail_window.project
            ~allow_empty_history:true
            ~measure_message_bytes:measure_model_input_message_bytes
            ~capacity_bytes
            ~reserved_bytes:0
            messages
        with
        | Ok projected -> Ok projected
        | Error error ->
          Error
            (Runtime_model_input_tail_window.budget_error_to_string error))
  in
  let* windowed = windowed in
  let () =
    Domain_pool_ref.submit_cpu_or_inline (fun () ->
      let full_bytes =
        List.fold_left
          (fun total message ->
             total + measure_model_input_message_bytes message)
          0
          windowed
      in
      let target_capacity_bytes =
        if capacity_bytes = unbounded_model_input_capacity_bytes
        then
          Keeper_turn_driver_try_provider.default_context_overflow_shrink_capacity
            ~capacity_bytes:full_bytes
        else
          Keeper_turn_driver_try_provider.default_context_overflow_shrink_capacity
            ~capacity_bytes
      in
      observed_next_shrink_capacity_bytes :=
        Runtime_model_input_tail_window.next_shrink_capacity_bytes
          ~allow_empty_history:true
          ~measure_message_bytes:measure_model_input_message_bytes
          ~target_capacity_bytes
          windowed;
      observed_floor_capacity_bytes :=
        Runtime_model_input_tail_window.minimum_capacity_bytes
          ~measure_message_bytes:measure_model_input_message_bytes
          windowed)
  in
  match source_projection with
  | None -> Ok windowed
  | Some project -> project windowed
;;

let claude_stream_callback on_event =
  match on_event with
  | None -> None
  | Some emit ->
    let next_tool_index = ref 1 in
    let tool_indexes = Hashtbl.create 8 in
    let streamed_text = Buffer.create 256 in
    Some
      (function
        | Runtime_claude_code.Turn_started { turn_id; model } ->
          emit (Agent_core.Types.MessageStart { id = turn_id; model; usage = None })
        | Runtime_claude_code.Text_delta text ->
          Buffer.add_string streamed_text text;
          emit
            (Agent_core.Types.ContentBlockDelta
               { index = 0; delta = Agent_core.Types.TextDelta text })
        | Runtime_claude_code.Dynamic_tool_started
            { call_id; tool_name; arguments } ->
          let index = !next_tool_index in
          incr next_tool_index;
          Hashtbl.replace tool_indexes call_id index;
          emit
            (Agent_core.Types.ContentBlockStart
               { index
               ; content_type = "tool_use"
               ; tool_id = Some call_id
               ; tool_name = Some tool_name
               });
          emit
            (Agent_core.Types.ContentBlockDelta
               { index
               ; delta =
                   Agent_core.Types.InputJsonSnapshot
                     (Yojson.Safe.to_string arguments)
               })
        | Runtime_claude_code.Dynamic_tool_finished { call_id } ->
          Option.iter
            (fun index ->
               Hashtbl.remove tool_indexes call_id;
               emit (Agent_core.Types.ContentBlockStop { index }))
            (Hashtbl.find_opt tool_indexes call_id)
        | Runtime_claude_code.Turn_finished { text } ->
          let streamed = Buffer.contents streamed_text in
          if String.starts_with ~prefix:streamed text
          then begin
            let suffix_length = String.length text - String.length streamed in
            if suffix_length > 0
            then
              emit
                (Agent_core.Types.ContentBlockDelta
                   { index = 0
                   ; delta =
                       Agent_core.Types.TextDelta
                         (String.sub text (String.length streamed) suffix_length)
                   })
          end;
          emit Agent_core.Types.MessageStop)
;;

let retry_after_of_rate_limit = function
  | None -> None
  | Some ({ resets_at = None; _ } : Runtime_claude_code.rate_limit) -> None
  | Some { resets_at = Some timestamp; _ } ->
    Some (Float.max 0.0 (Float.of_int timestamp -. Time_compat.now ()))
;;

let claude_error_to_core_error = function
  | Runtime_claude_code.Invalid_config detail ->
    config_error ~field:"claude_code" detail
  | Runtime_claude_code.Subscription_required detail ->
    Agent_core.Error.Provider
      (Llm_provider.Error.AuthError { provider = "claude_code"; detail })
  | Runtime_claude_code.Quota_blocked ({ rate_limit; _ } as blocked) ->
    Agent_core.Error.Provider
      (Llm_provider.Error.HardQuota
         { provider = "claude_code"
         ; retry_after = retry_after_of_rate_limit rate_limit
         ; detail = Runtime_claude_code.error_to_string (Quota_blocked blocked)
         })
  | Runtime_claude_code.Turn_failed detail ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderReportedError
         { provider = "claude_code"; error_type = Some "turn_failed"; detail })
  | Runtime_claude_code.Timeout seconds ->
    Agent_core.Error.Api
      (Agent_core.Retry.Timeout
         { message = Printf.sprintf "Claude Code turn timed out after %.3fs" seconds
         ; phase = None
         })
  | Runtime_claude_code.Spawn_failed detail
  | Runtime_claude_code.Process_exited detail ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderUnavailable
         { provider = "claude_code"; detail })
  | Runtime_claude_code.Turn_transport_interrupted _ as error ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderUnavailable
         { provider = "claude_code"
         ; detail = Runtime_claude_code.error_to_string error
         })
  | Runtime_claude_code.Context_window_exceeded
      { message; tool_effect_attempted = false; response_emitted = false } ->
    Agent_core.Error.Api
      (Llm_provider.Retry.ContextOverflow { message; limit = None })
  | Runtime_claude_code.Context_window_exceeded _ as error ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderReportedError
         { provider = "claude_code"
         ; error_type = Some "context_window_exceeded_after_observed_activity"
         ; detail = Runtime_claude_code.error_to_string error
         })
  | Runtime_claude_code.Protocol_error { stage; detail } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ParseError
         { detail = Printf.sprintf "%s: %s" stage detail })
  | Runtime_claude_code.Unsupported_control_request subtype ->
    Agent_core.Error.Provider
      (Llm_provider.Error.UnknownVariant
         { type_name = "claude_code.control_request"; value = subtype })
  | Runtime_claude_code.Stopped_by_host _ ->
    Agent_core.Error.Internal
      "Claude Code host stop escaped the typed checkpoint boundary"
;;

let recovery_failure_of_client_error = function
  | Runtime_claude_code.Spawn_failed _ -> Session_store.Transient_spawn_failed
  | Runtime_claude_code.Process_exited _ | Runtime_claude_code.Timeout _ ->
    Session_store.Transport_interrupted
  | Runtime_claude_code.Turn_transport_interrupted _ ->
    Session_store.Transport_interrupted
  | Runtime_claude_code.Invalid_config _
  | Runtime_claude_code.Protocol_error _
  | Runtime_claude_code.Unsupported_control_request _ ->
    Session_store.Protocol_failed
  | Runtime_claude_code.Subscription_required _
  | Runtime_claude_code.Context_window_exceeded _
  | Runtime_claude_code.Turn_failed _
  | Runtime_claude_code.Quota_blocked _ ->
    Session_store.Provider_rejected
  | Runtime_claude_code.Stopped_by_host _ -> Session_store.Protocol_failed
;;

let run_without_lifecycle ~runtime_id ~keeper_name
    ~pre_tool_rejects ~base_path ~goal ~goal_blocks ~system_prompt
    ~tools ~initial_messages ~model_input_projection ~hooks ~context_injector
    ~context ~terminal_effect_state ~event_bus ~raw_trace ~on_event ~effect_disposition
    ~context_overflow_retry_safe
    ~(config : Runtime_execution.claude_code) =
  context_overflow_retry_safe := false;
  match Eio_context.get_env_opt (), Eio_context.get_clock_opt () with
  | None, _ ->
    Error
      (config_error
         ~field:"eio_env"
         "Claude Code runtime requires the initialized Eio standard environment")
  | _, None ->
    Error
      (config_error
         ~field:"eio_clock"
         "Claude Code runtime requires the initialized Eio clock")
  | Some env, Some clock ->
    let hooks =
      match hooks with
      | Some hooks -> hooks
      | None -> Agent_core.Hooks.empty
    in
    let owner_epoch = Session_store.process_epoch () in
    let* stored_session =
      match Session_store.load ~base_path ~keeper_name with
      | Ok session -> Ok session
      | Error detail ->
        Error (internal_error ("Claude Code session binding load failed: " ^ detail))
    in
    let* stored_session =
      match stored_session with
      | Some ({ phase = (Start _ | Active _ | Turn_inflight _); _ } as expected) ->
        (match
           Session_store.reconcile_process_restart
             ~base_path
             ~keeper_name
             ~expected
             ~current_owner_epoch:owner_epoch
             ~required_at:(Time_compat.now ())
         with
         | Ok reconciled -> Ok (Some reconciled)
         | Error detail ->
           Error (config_error ~field:"official_client_session.phase" detail))
      | None | Some { phase = (Ready | Recovery_required _ | Settled _); _ } ->
        Ok stored_session
    in
    let* claim_plan =
      match
        Session_store.plan_claim
          ~expected:stored_session
          ~client_kind:Claude_code
          ~runtime_id
      with
      | Ok plan -> Ok plan
      | Error detail ->
        Error (config_error ~field:"official_client_session.claim" detail)
    in
    (* Before the plan is read; see the same note in keeper_codex_runtime.ml. *)
    let tool_surface_sha256 = Session_store.tool_surface_sha256 tools in
    let claim_plan =
      Session_store.reconcile_tool_surface claim_plan ~tool_surface_sha256
    in
    let session_mode =
      match claim_plan.previous_settlement with
      | None -> Runtime_claude_code.Start
      | Some { session_id; _ } -> Runtime_claude_code.Resume { session_id }
    in
    let turn_count = claim_plan.turn_count in
    let* prepared =
      Host.prepare_turn
        ~configured_reasoning_effort:
          (Runtime_inference.resolve_reasoning_effort ~runtime_id)
        ~runtime_label
        ~keeper_name
        ~turn_count
        ~system_prompt
        ~tools
        ~initial_messages
        ~model_input_projection
        ~hooks:(Some hooks)
    in
    let* system_messages, history = project_messages prepared.messages in
    let* goal =
      match goal_blocks with
      | None -> Ok goal
      | Some blocks -> Host.text_of_blocks ~runtime_label ~field:"goal_blocks" blocks
    in
    let prompt =
      match session_mode with
      | Runtime_claude_code.Start -> initial_turn_prompt ~history ~goal
      | Runtime_claude_code.Resume _ -> goal
    in
    let system_prompt =
      prepared.system_prompt :: system_messages
      |> List.filter (fun text -> String.trim text <> "")
      |> String.concat "\n\n"
      |> String_util.trim_nonempty
    in
    let client_config : Runtime_claude_code.config =
      { cli_path = config.cli_path
      ; cwd = base_path
      ; model = config.model
      ; system_prompt
      ; admission_timeout_s = config.timeout_s
      ; (* A per-model [turn-timeout-s] overrides the stream-idle bound, and
           [0] removes it: the deadline exists to notice a client that has gone
           silent, not to cap how long legitimate work may take, so a
           deployment is allowed to say the client decides. Absent leaves
           [config.timeout_s] standing, which keeps an undeclared config on the
           previous behaviour. *)
        timeout_s =
          (match Runtime_inference.resolve_turn_timeout_s ~runtime_id with
           | None -> Some config.timeout_s
           | Some seconds when seconds <= 0.0 -> None
           | Some seconds -> Some seconds)
      }
    in
    let terminal_error = ref None in
    let* host_dynamic_tools =
      Host.dynamic_tools
        (* These lanes drive a provider CLI that has no place to show an
           operator prompt mid-turn, so a decision asking for one is rejected
           rather than admitted. *)
        ~tool_approval:None
        ~runtime_label
        ~keeper_name
        ~turn_count
        ~tools:prepared.tools
        ~hooks
        ~event_bus
        ~context_injector
        ~context
        ~terminal_effect_state
        ~terminal_error
        ~pre_tool_rejects
        ~raw_trace_run:None
    in
    let dynamic_tools = host_dynamic_tools in
    let* () =
      match
        Runtime_claude_code.validate_turn
          ~dynamic_tools
          ~session_mode
          client_config
          ~prompt
      with
      | Ok () -> Ok ()
      | Error error -> Error (claude_error_to_core_error error)
    in
    let process_mgr = Eio.Stdenv.process_mgr env in
    let process_cwd = Eio.Path.(Eio.Stdenv.fs env / base_path) in
    let probe_config =
      bounded_probe_config ~fallback_timeout_s:config.timeout_s client_config
    in
    let* admitted_subscription =
      match
        Runtime_claude_code.probe_subscription
          ~mgr:process_mgr
          ~clock
          ~cwd:process_cwd
          probe_config
      with
      | Ok subscription -> Ok subscription
      | Error error -> Error (claude_error_to_core_error error)
    in
    let raw_trace_run =
      Host.start_raw_trace
        ~keeper_name
        ~raw_trace
        ~prompt
        ?model:config.model
        ?reasoning_effort:
          (Option.map
             Llm_provider.Reasoning_effort.to_string
             prepared.reasoning_effort)
        ()
    in
    let* host_dynamic_tools =
      Host.dynamic_tools
        (* These lanes drive a provider CLI that has no place to show an
           operator prompt mid-turn, so a decision asking for one is rejected
           rather than admitted. *)
        ~tool_approval:None
        ~runtime_label
        ~keeper_name
        ~turn_count
        ~tools:prepared.tools
        ~hooks
        ~event_bus
        ~context_injector
        ~context
        ~terminal_effect_state
        ~terminal_error
        ~pre_tool_rejects
        ~raw_trace_run
    in
    let dynamic_tools = host_dynamic_tools in
    let* claimed_session =
      match
        Session_store.claim
          ~base_path
          ~keeper_name
          ~expected:stored_session
          ~client_kind:Claude_code
          ~owner_epoch
          ~runtime_id
          ~tool_surface_sha256
          ~updated_at:(Time_compat.now ())
      with
      | Ok session -> Ok session
      | Error detail ->
        let error = internal_error ("Claude Code session claim failed: " ^ detail) in
        Host.finish_raw_error ~keeper_name raw_trace_run error;
        Error error
    in
    let session_state = ref claimed_session in
    let recovery_failure = ref Session_store.Transport_interrupted in
    let state_persistence_failed = ref false in
    let update_session label transition =
      match transition !session_state with
      | Ok next ->
        session_state := next;
        Ok ()
      | Error detail ->
        state_persistence_failed := true;
        recovery_failure := Session_store.State_persistence_failed;
        Error (Printf.sprintf "Claude Code session %s failed: %s" label detail)
    in
    let require_recovery detail =
      match !session_state with
      | { Session_store.phase = (Ready | Settled _ | Recovery_required _); _ } ->
        Ok ()
      | expected ->
        (match
           Session_store.require_recovery
             ~base_path
             ~keeper_name
             ~expected
             ~failure:!recovery_failure
             ~detail
             ~required_at:(Time_compat.now ())
         with
         | Ok recovery ->
           session_state := recovery;
           Ok ()
         | Error detail -> Error detail)
    in
    let settle_failed_claim detail =
      match Session_store.failure_disposition !recovery_failure with
      | Transient ->
        (match !session_state with
         | { phase = (Ready | Settled _ | Recovery_required _); _ } -> Ok ()
         | expected ->
           (match
              Session_store.release_transient
                ~base_path
                ~keeper_name
                ~expected
                ~failure:!recovery_failure
                ~released_at:(Time_compat.now ())
            with
            | Ok released ->
              session_state := released;
              Ok ()
            | Error detail -> Error detail))
      | Ambiguous | Fatal -> require_recovery detail
    in
    (* Same gap #28101 closed for Codex, on the other official-client path. A
       claude_code turn resumes a server-side session, so the accumulated
       conversation is not held here and cannot be measured from this process.
       What this process does send every turn - the prompt, the system prompt
       and the tool declarations - is measurable, and a live refusal says that
       part alone is the problem: a live Keeper was told the request is ~2,226,104
       tokens against a 1,000,000 limit while "this conversation is only
       ~1,094,432 tokens - the rest is system prompt, tool definitions, and
       attachment content" (#27427). Recording the half this process controls
       is what lets that sentence be checked against a number rather than
       believed. Sizes are bytes this process holds, not provider tokens. *)
    Log.Keeper.info
      ~keeper_name
      "%s turn composition: mode=%s prompt_bytes=%d system_prompt_bytes=%d \
       tools=%d tool_surface_bytes=%d"
      runtime_label
      (match session_mode with
       | Runtime_claude_code.Start -> "start"
       | Runtime_claude_code.Resume _ -> "resume")
      (String.length prompt)
      (Option.fold ~none:0 ~some:String.length client_config.Runtime_claude_code.system_prompt)
      (List.length dynamic_tools)
      (Runtime_claude_code.dynamic_tool_bytes dynamic_tools);
    let started_at = Time_compat.now () in
    let settle_host_stop stop =
      match (!session_state).Session_store.phase with
      | Turn_inflight { session_id; turn_id; _ } ->
        let turn_id =
          Option.value
            turn_id
            ~default:(host_stop_turn_identity ~session_id ~turn_count)
        in
        let* () =
          match turn_id, (!session_state).phase with
          | turn_id, Turn_inflight { turn_id = None; _ } ->
            update_session "host-stop turn identity transition" (fun expected ->
              Session_store.mark_turn_started
                ~base_path
                ~keeper_name
                ~expected
                ~session_id
                ~turn_id
                ~turn_count
                ~updated_at:(Time_compat.now ()))
            |> Result.map_error internal_error
          | _, Turn_inflight { turn_id = Some _; _ } -> Ok ()
          | _, _ -> assert false
        in
        let projected =
          Host.host_stop_result
            ~model:(Option.value config.model ~default:runtime_id)
            ~session_id
            ~turn_id
            ~turns_used:turn_count
            stop
        in
        let* () =
          match projected with
          | Error _ -> Ok ()
          | Ok result ->
            Host.invoke_turn_completion_hooks
              ~runtime_label
              ~keeper_name
              ~turn_count
              ~hooks
              result.response
        in
        recovery_failure := Session_store.State_persistence_failed;
        (match
           Session_store.settle
             ~base_path
             ~keeper_name
             ~expected:!session_state
             ~session_id
             ~turn_id
             ~updated_at:(Time_compat.now ())
         with
         | Error detail ->
           Error
             (internal_error
                ("Claude Code host-stop settlement failed: " ^ detail))
         | Ok settled ->
           session_state := settled;
           projected)
      | Ready | Start _ | Active _ | Recovery_required _ | Settled _ ->
        Error
          (internal_error
             "Claude Code host stop arrived without an acknowledged provider turn")
    in
    let turn_result =
      let on_stream_event = claude_stream_callback on_event in
      try
        let client_result =
           Runtime_claude_code.run_turn
             ~on_spawned:(fun () ->
               Atomic.set
                 effect_disposition
                 Keeper_provider_attempt_effect.Observation_unavailable)
             ~mgr:process_mgr
             ~clock
             ~cwd:process_cwd
             ~dynamic_tools
             ?reasoning_effort:prepared.reasoning_effort
             ~session_mode
             ~admitted_subscription
             ~on_session_ready:(fun ~session_id ->
               update_session "active transition" (fun expected ->
                 Session_store.mark_active
                   ~base_path
                   ~keeper_name
                   ~expected
                   ~session_id
                   ~updated_at:(Time_compat.now ())))
             ~on_turn_starting:(fun ~session_id ->
               update_session "turn-starting transition" (fun expected ->
                 Session_store.mark_turn_starting
                   ~base_path
                   ~keeper_name
                   ~expected
                   ~session_id
                   ~updated_at:(Time_compat.now ())))
             ~on_turn_started:(fun ~session_id ~turn_id ->
               update_session "turn-started transition" (fun expected ->
                 Session_store.mark_turn_started
                   ~base_path
                   ~keeper_name
                   ~expected
                   ~session_id
                   ~turn_id
                   ~turn_count
                   ~updated_at:(Time_compat.now ())))
             ?on_stream_event
             client_config
             ~prompt
        in
        (match client_result with
         | Error (Runtime_claude_code.Stopped_by_host stop) ->
           recovery_failure := Session_store.Host_hook_failed;
           (match !terminal_error with
            | Some detail -> Error (internal_error detail)
            | None -> settle_host_stop stop)
         | Error error ->
           context_overflow_retry_safe :=
             (match error with
              | Runtime_claude_code.Context_window_exceeded
                  { tool_effect_attempted = false; response_emitted = false; _ } ->
                true
              | _ -> false);
           if not !state_persistence_failed
           then recovery_failure := recovery_failure_of_client_error error;
           Error (claude_error_to_core_error error)
         | Ok turn ->
           recovery_failure := Session_store.Protocol_failed;
           let expected_resumed =
             match session_mode with
             | Runtime_claude_code.Start -> false
             | Runtime_claude_code.Resume _ -> true
           in
           let* () =
             if Bool.equal expected_resumed turn.resumed
             then Ok ()
             else
               Error
                 (internal_error
                    "Claude Code reported a session mode different from the durable claim plan")
           in
           recovery_failure := Session_store.Host_hook_failed;
           let* () =
             match !terminal_error with
             | None -> Ok ()
             | Some detail -> Error (internal_error detail)
           in
           let latency_ms =
             Int.of_float ((Time_compat.now () -. started_at) *. 1000.0)
           in
           let response =
             { Agent_core.Types.id = turn.turn_id
             ; model = turn.model
             ; stop_reason = EndTurn
             ; content = [ Text turn.text ]
             ; usage =
                 (* The CLI frame carries Anthropic exclusive counts; the
                    shared constructor produces the canonical inclusive
                    api_usage. *)
                 Option.map
                   (fun (usage : Runtime_claude_code.turn_usage) ->
                      Agent_core.Llm_provider.Backend_anthropic.usage_of_wire_counts
                        ~input_tokens:usage.input_tokens
                        ~output_tokens:usage.output_tokens
                        ~cache_creation_input_tokens:
                          usage.cache_creation_input_tokens
                        ~cache_read_input_tokens:usage.cache_read_input_tokens)
                   turn.usage
             ; telemetry =
                 Some
                   { Agent_core.Types.default_inference_telemetry with
                     request_latency_ms = Some latency_ms
                   ; canonical_model_id = Some turn.model
                   }
             }
           in
           let* () =
             Host.invoke_turn_completion_hooks
               ~runtime_label
               ~keeper_name
               ~turn_count
               ~hooks
               response
           in
           recovery_failure := Session_store.State_persistence_failed;
           let* () =
             match
               Session_store.settle
                 ~base_path
                 ~keeper_name
                 ~expected:!session_state
                 ~session_id:turn.session_id
                 ~turn_id:turn.turn_id
                 ~updated_at:(Time_compat.now ())
             with
             | Ok settled ->
               session_state := settled;
               Ok ()
             | Error detail ->
               Error
                 (internal_error
                    ("Claude Code session settlement failed: " ^ detail))
           in
           let capture, _metrics =
             Runtime_observation.runtime_metrics_for_candidates ()
           in
           Runtime_observation.record_attempt_terminal
             capture
             ~model_id:turn.model
             ~latency_ms:(Some latency_ms)
             ~error:None;
           let runtime_observation =
             Runtime_observation.runtime_observation_with_metrics
               ~runtime_id
               ~selected_model_raw:(Some turn.model)
               ~capture
               ~attempt_details_source:"claude_code"
               ~agent_core_internal_runtime_allowed:false
               ()
           in
           Ok
             { Runtime_agent.response
             ; checkpoint = None
             ; session_id = turn.session_id
             ; turns = turn_count
             ; trace_ref = None
             ; run_validation = None
             ; runtime_observation = Some runtime_observation
             ; stop_reason = Completed
             })
      with
      (* A stop the owner raised is not an ambiguity: it knows the turn did
         not finish and why. Only an unexplained cancellation needs an
         operator to adjudicate what the transport left behind (#28012). *)
      | Eio.Cancel.Cancelled _ as exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        recovery_failure
          := (match exn with
              | Eio.Cancel.Cancelled Keeper_owner_signals.Stop_active_child ->
                Session_store.Owner_stopped_turn
              | _ -> Session_store.Transport_interrupted);
        let detail = "Claude Code turn cancelled: " ^ Printexc.to_string exn in
        (match Eio.Cancel.protect (fun () -> settle_failed_claim detail) with
         | Ok () -> ()
         | Error recovery_detail ->
           Log.Keeper.error
             ~keeper_name
             "Claude Code cancellation recovery persistence failed: %s"
             recovery_detail);
        Eio.Cancel.protect (fun () ->
          Host.finish_raw_error ~keeper_name raw_trace_run (internal_error detail));
        Printexc.raise_with_backtrace exn backtrace
    in
    let turn_result =
      match turn_result with
      | Ok result -> Ok (Host.finish_raw_success ~keeper_name raw_trace_run result)
      | Error error ->
        Host.finish_raw_error ~keeper_name raw_trace_run error;
        Error error
    in
    (match turn_result with
     | Ok _ -> turn_result
     | Error original_error ->
       let original_detail = Agent_core.Error.to_string original_error in
       (match Eio.Cancel.protect (fun () -> settle_failed_claim original_detail) with
        | Ok () -> turn_result
        | Error recovery_detail ->
          Error
            (internal_error
               (Printf.sprintf
                  "Claude Code turn failed and recovery state persistence also failed: original=%s recovery=%s"
                  original_detail
                  recovery_detail))))
;;

let run ~runtime_id ~keeper_name ~pre_tool_rejects ~base_path ~goal ~goal_blocks ~system_prompt
    ~tools ~initial_messages ~model_input_projection ~hooks ~context_injector
    ~context
    ?(terminal_effect_state = fun () -> Keeper_tools_agent_core.Terminal_effect_open)
    ~event_bus ~raw_trace ~on_event ~config () =
  let effect_disposition =
    Atomic.make Keeper_provider_attempt_effect.No_effect_observed
  in
  let observed_next_shrink_capacity_bytes = ref None in
  let observed_floor_capacity_bytes = ref None in
  let context_overflow_retry_safe = ref false in
  let starting_capacity_bytes =
    Keeper_context_overflow_shrink_state.starting_capacity_bytes
      ~keeper_name
      ~runtime_id
      ~max_capacity_bytes:unbounded_model_input_capacity_bytes
  in
  let result =
    Host.with_run_lifecycle_events ~event_bus ~keeper_name (fun () ->
      Keeper_turn_driver_try_provider.context_overflow_shrink_sequence
        ~starting_capacity_bytes
        ~same_run_retry_authorized:(fun () ->
          !context_overflow_retry_safe
          && Option.is_some !observed_next_shrink_capacity_bytes)
        ~shrink_capacity:(fun ~capacity_bytes:_ ~default_capacity_bytes ->
          Option.value
            !observed_next_shrink_capacity_bytes
            ~default:(max 1 default_capacity_bytes))
        ~final_shrink_capacity:(fun ~capacity_bytes:_ ->
          !observed_floor_capacity_bytes)
        ~record_success:(fun ~capacity_bytes ->
          if capacity_bytes <> unbounded_model_input_capacity_bytes
          then
            Keeper_context_overflow_shrink_state.record_success
              ~keeper_name
              ~runtime_id
              ~capacity_bytes)
        ~on_shrink_retry:
          (fun ~shrink_attempt ~previous_capacity_bytes ~capacity_bytes ->
            Log.Keeper.warn
              ~keeper_name
              "Claude typed context overflow; shrinking provider-bound history: attempt=%d previous_capacity_bytes=%d capacity_bytes=%d"
              shrink_attempt
              previous_capacity_bytes
              capacity_bytes)
        ~attempt:(fun ~capacity_bytes ->
          run_without_lifecycle
            ~runtime_id
            ~keeper_name
    ~pre_tool_rejects
            ~base_path
            ~goal
            ~goal_blocks
            ~system_prompt
            ~tools
            ~initial_messages
            ~model_input_projection:
              (Some
                 (model_input_projection_for_capacity
                    ~capacity_bytes
                    ~observed_next_shrink_capacity_bytes
                    ~observed_floor_capacity_bytes
                    model_input_projection))
            ~hooks
          ~context_injector
          ~context
          ~terminal_effect_state
          ~event_bus
            ~raw_trace
            ~on_event
            ~effect_disposition
            ~context_overflow_retry_safe
            ~config)
        ())
  in
  { result; effect_disposition = Atomic.get effect_disposition }
;;
