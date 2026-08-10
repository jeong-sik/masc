open Result.Syntax

module Host = Keeper_official_client_host
module Session_store = Keeper_official_client_session_store

let runtime_label = "Antigravity"

let config_error ~field detail =
  Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; detail })
;;

let internal_error detail = Agent_core.Error.Internal detail

let runtime_error_to_core_error = function
  | Runtime_antigravity.Invalid_config detail ->
    config_error ~field:"antigravity_cli" detail
  | Runtime_antigravity.Prompt_too_large { bytes; limit } ->
    (* The prompt is assembled here, so a prompt this runtime cannot spawn is
       this layer's own construction error, not the provider's. *)
    internal_error
      (Printf.sprintf
         "Antigravity prompt was %d bytes against a %d byte command-line budget"
         bytes
         limit)
  | Runtime_antigravity.Turn_failed detail ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderReportedError
         { provider = "antigravity_cli"
         ; error_type = Some "turn_failed"
         ; detail
         })
  | Runtime_antigravity.Timeout seconds ->
    Agent_core.Error.Api
      (Agent_core.Retry.Timeout
         { message = Printf.sprintf "Antigravity turn timed out after %.3fs" seconds
         ; phase = None
         })
  | Runtime_antigravity.Spawn_failed detail
  | Runtime_antigravity.Process_exited detail ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderUnavailable
         { provider = "antigravity_cli"; detail })
  | Runtime_antigravity.Protocol_error { stage; detail } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ParseError
         { detail = Printf.sprintf "%s: %s" stage detail })
  | Runtime_antigravity.State_callback_failed detail -> internal_error detail
;;

let recovery_failure_of_runtime_error = function
  | Runtime_antigravity.Spawn_failed _ -> Session_store.Transient_spawn_failed
  | Runtime_antigravity.Process_exited _ | Runtime_antigravity.Timeout _ ->
    Session_store.Transport_interrupted
  | Runtime_antigravity.Invalid_config _
  | Runtime_antigravity.Protocol_error _ ->
    Session_store.Protocol_failed
  | Runtime_antigravity.Prompt_too_large _ ->
    (* Retrying the same claim rebuilds the same oversized prompt, so this is a
       persistence-class stop for an operator, not a transient release. *)
    Session_store.State_persistence_failed
  | Runtime_antigravity.State_callback_failed _ ->
    Session_store.State_persistence_failed
  | Runtime_antigravity.Turn_failed _ -> Session_store.Provider_rejected
;;

let home_error_to_core_error error =
  config_error
    ~field:"antigravity_home"
    (Runtime_antigravity_home.error_to_string error)
;;

let render_message (message : Agent_core.Types.message) =
  let text = Host.encode_history_message message in
  match message.role with
  | Agent_core.Types.System -> Ok ("SYSTEM:\n" ^ text)
  | Agent_core.Types.User -> Ok ("USER:\n" ^ text)
  | Agent_core.Types.Assistant -> Ok ("ASSISTANT:\n" ^ text)
  | Agent_core.Types.Tool -> Ok ("TOOL:\n" ^ text)
;;

type prompt_projection =
  { prompt : string
  ; history_kept_messages : int
  ; history_dropped_messages : int
  }

let section_separator = "\n\n"

(* A resumed turn sends only the goal because the CLI still holds the
   conversation. A fresh one has to re-seed it, and that seed is the whole
   rendered history -- which the CLI takes as one command-line argument. Past
   the kernel's cap the spawn fails outright, so a Keeper whose history had
   grown could not start a fresh session at all (#28051, live 2026-08-10).

   The system prompt and the current goal are what the turn is; they are never
   dropped, and if they alone do not fit the turn is refused rather than
   silently reshaped. History is the part that can be partial, so it is fitted
   newest-first into whatever budget remains and the caller is told how many
   messages did not fit. *)
let fit_history_to_budget ~budget messages =
  let rec loop kept kept_bytes = function
    | [] -> kept, kept_bytes, 0
    | message :: older ->
      (match render_message message with
       | Error _ -> kept, kept_bytes, List.length (message :: older)
       | Ok rendered ->
         let separator = if kept = [] then 0 else String.length section_separator in
         let next_bytes = kept_bytes + separator + String.length rendered in
         if next_bytes > budget
         then kept, kept_bytes, List.length (message :: older)
         else loop (rendered :: kept) next_bytes older)
  in
  let kept, _, dropped = loop [] 0 (List.rev messages) in
  String.concat section_separator kept, List.length kept, dropped
;;

let prompt_for_turn ~is_resume ~goal (prepared : Host.prepared_turn) =
  if is_resume
  then
    Ok { prompt = goal; history_kept_messages = 0; history_dropped_messages = 0 }
  else
    let framed_system =
      String_util.trim_to_option prepared.system_prompt
      |> Option.map (fun value -> "SYSTEM INSTRUCTIONS:\n" ^ value)
    in
    let framed_goal = "CURRENT GOAL:\n" ^ goal in
    let required =
      [ framed_system; Some framed_goal ]
      |> List.filter_map Fun.id
      |> String.concat section_separator
    in
    let required_bytes = String.length required in
    if required_bytes >= Runtime_antigravity.max_prompt_bytes
    then
      Error
        (internal_error
           (Printf.sprintf
              "Antigravity fresh-session prompt needs %d bytes for the system \
               prompt and goal alone; the CLI accepts at most %d"
              required_bytes
              Runtime_antigravity.max_prompt_bytes))
    else
      let budget =
        Runtime_antigravity.max_prompt_bytes
        - required_bytes
        - String.length section_separator
      in
      let history, history_kept_messages, history_dropped_messages =
        fit_history_to_budget ~budget prepared.messages
      in
      let prompt =
        [ framed_system
        ; String_util.trim_to_option history
        ; Some framed_goal
        ]
        |> List.filter_map Fun.id
        |> String.concat section_separator
      in
      Ok { prompt; history_kept_messages; history_dropped_messages }
;;

let tool_spec (tool : Host.dynamic_tool) =
  `Assoc
    [ "name", `String tool.name
    ; "description", `String tool.description
    ; "inputSchema", tool.input_schema
    ]
;;

let tool_result (result : Host.dynamic_tool_result) =
  { Runtime_official_client_mcp.success = result.success
  ; content = result.content
  }
;;

let find_tool tools name =
  List.find_opt (fun (tool : Host.dynamic_tool) -> String.equal tool.name name) tools
;;

let provider_turn_identity ~conversation_id ~num_turns =
  Printf.sprintf "%s:ordinal:%d" conversation_id num_turns
;;

let run_without_lifecycle ~runtime_id ~keeper_name ~base_path ~goal ~goal_blocks
    ~system_prompt ~tools ~initial_messages ~model_input_projection ~hooks
    ~context_injector ~context ~event_bus ~raw_trace
    ~(config : Runtime_execution.antigravity_cli) =
  match Eio_context.get_env_opt (), Eio_context.get_clock_opt () with
  | None, _ ->
    Error
      (config_error
         ~field:"eio_env"
         "Antigravity runtime requires the initialized Eio standard environment")
  | _, None ->
    Error
      (config_error
         ~field:"eio_clock"
         "Antigravity runtime requires the initialized Eio clock")
  | Some env, Some clock ->
    let hooks = Option.value hooks ~default:Agent_core.Hooks.empty in
    let owner_epoch = Session_store.process_epoch () in
    let* stored_session =
      Session_store.load ~base_path ~keeper_name
      |> Result.map_error (fun detail ->
        internal_error ("Antigravity session binding load failed: " ^ detail))
    in
    let* stored_session =
      match stored_session with
      | Some ({ phase = (Start _ | Active _ | Turn_inflight _); _ } as expected) ->
        Session_store.reconcile_process_restart
          ~base_path
          ~keeper_name
          ~expected
          ~current_owner_epoch:owner_epoch
          ~required_at:(Time_compat.now ())
        |> Result.map Option.some
        |> Result.map_error (fun detail ->
          config_error ~field:"official_client_session.phase" detail)
      | None | Some { phase = (Ready | Recovery_required _ | Settled _); _ } ->
        Ok stored_session
    in
    let* claim_plan =
      Session_store.plan_claim
        ~expected:stored_session
        ~client_kind:Antigravity
        ~runtime_id
      |> Result.map_error (fun detail ->
        config_error ~field:"official_client_session.claim" detail)
    in
    (* Before the plan is read; see the note in keeper_codex_runtime.ml. A
       moved surface has to change conversation_mode and the ordinal too, not
       just what the store writes. *)
    let tool_surface_sha256 = Session_store.tool_surface_sha256 tools in
    let claim_plan =
      Session_store.reconcile_tool_surface claim_plan ~tool_surface_sha256
    in
    let conversation_mode =
      match claim_plan.previous_settlement with
      | None -> Runtime_antigravity.Start
      | Some { session_id; _ } ->
        Runtime_antigravity.Resume { conversation_id = session_id }
    in
    let is_resume = Option.is_some claim_plan.previous_settlement in
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
    let* () =
      match prepared.reasoning_effort with
      | None -> Ok ()
      | Some _ when Option.is_some config.effort ->
        Error
          (config_error
             ~field:"reasoning_effort"
             "Antigravity effort has two configured owners")
      | Some _ ->
        Error
          (config_error
             ~field:"reasoning_effort"
             "Antigravity effort must be declared by its runtime provider")
    in
    let* goal =
      match goal_blocks with
      | None -> Ok goal
      | Some blocks -> Host.text_of_blocks ~runtime_label ~field:"goal_blocks" blocks
    in
    let* projected_prompt = prompt_for_turn ~is_resume ~goal prepared in
    let prompt = projected_prompt.prompt in
    if projected_prompt.history_dropped_messages > 0
    then
      Log.Keeper.warn
        ~keeper_name
        "Antigravity fresh session seeded with %d of %d history message(s); %d \
         did not fit the CLI's command-line prompt budget of %d bytes"
        projected_prompt.history_kept_messages
        (projected_prompt.history_kept_messages
         + projected_prompt.history_dropped_messages)
        projected_prompt.history_dropped_messages
        Runtime_antigravity.max_prompt_bytes;
    let terminal_error = ref None in
    let* dynamic_tools =
      Host.dynamic_tools
        ~runtime_label
        ~keeper_name
        ~turn_count
        ~tools:prepared.tools
        ~hooks
        ~event_bus
        ~context_injector
        ~context
        ~terminal_error
        ~raw_trace_run:None
    in
    let runtime_root = Common.masc_dir_from_base_path ~base_path in
    let* home =
      Runtime_antigravity_home.prepare
        ~runtime_root
        ~owner_leaf:keeper_name
        ~oauth_source:config.oauth_source
      |> Result.map_error home_error_to_core_error
    in
    let client_config : Runtime_antigravity.config =
      { cli_path = config.cli_path
      ; cwd = base_path
      ; model = config.model
      ; agent = config.agent
      ; effort = config.effort
      ; execution_mode = Plan
      ; sandbox = true
      ; disable_slash_commands = true
      ; (* A per-model [turn-timeout-s] overrides the admission-time bound.
           Absent, [config.timeout_s] stands, so a config that declares none
           behaves exactly as before. *)
        timeout_s =
          Option.value
            (Runtime_inference.resolve_turn_timeout_s ~runtime_id)
            ~default:config.timeout_s
      }
    in
    let* () =
      Runtime_antigravity.validate_turn
        ~conversation_mode
        client_config
        ~prompt
      |> Result.map_error runtime_error_to_core_error
    in
    let raw_trace_run =
      Host.start_raw_trace
        ~keeper_name
        ~raw_trace
        ~prompt
        ~model:config.model
        ?reasoning_effort:
          (Option.map
             (function
               | Runtime_antigravity.Low -> "low"
               | Runtime_antigravity.Medium -> "medium"
               | Runtime_antigravity.High -> "high")
             config.effort)
        ()
    in
    let* dynamic_tools =
      Host.dynamic_tools
        ~runtime_label
        ~keeper_name
        ~turn_count
        ~tools:prepared.tools
        ~hooks
        ~event_bus
        ~context_injector
        ~context
        ~terminal_error
        ~raw_trace_run
    in
    let* claimed_session =
      match
        Session_store.claim
          ~base_path
          ~keeper_name
          ~expected:stored_session
          ~client_kind:Antigravity
          ~owner_epoch
          ~runtime_id
          ~tool_surface_sha256
          ~updated_at:(Time_compat.now ())
      with
      | Ok session -> Ok session
      | Error detail ->
        let error = internal_error ("Antigravity session claim failed: " ^ detail) in
        Host.finish_raw_error ~keeper_name raw_trace_run error;
        Error error
    in
    let session_state = ref claimed_session in
    let recovery_failure = ref Session_store.Transport_interrupted in
    let update_session label transition =
      match transition !session_state with
      | Ok next ->
        session_state := next;
        Ok ()
      | Error detail ->
        recovery_failure := Session_store.State_persistence_failed;
        Error (Printf.sprintf "Antigravity session %s failed: %s" label detail)
    in
    let require_recovery detail =
      match !session_state with
      | { Session_store.phase = (Ready | Settled _ | Recovery_required _); _ } ->
        Ok ()
      | expected ->
        Session_store.require_recovery
          ~base_path
          ~keeper_name
          ~expected
          ~failure:!recovery_failure
          ~detail
          ~required_at:(Time_compat.now ())
        |> Result.map (fun recovery -> session_state := recovery)
    in
    let settle_failed_claim detail =
      match Session_store.failure_disposition !recovery_failure with
      | Transient ->
        (match !session_state with
         | { phase = (Ready | Settled _ | Recovery_required _); _ } -> Ok ()
         | expected ->
           Session_store.release_transient
             ~base_path
             ~keeper_name
             ~expected
             ~failure:!recovery_failure
             ~released_at:(Time_compat.now ())
           |> Result.map (fun released -> session_state := released))
      | Ambiguous | Fatal -> require_recovery detail
    in
    let process_mgr = Eio.Stdenv.process_mgr env in
    let process_cwd = Eio.Path.(Eio.Stdenv.fs env / base_path) in
    let started_at = Time_compat.now () in
    let run_client () =
      let cleanup_error = ref None in
      let turn_result =
        Eio.Switch.run (fun sw ->
          Eio.Switch.on_release sw (fun () ->
            match Eio.Cancel.protect (fun () -> Runtime_antigravity_home.clear_mcp_config home) with
            | Ok () -> ()
            | Error error -> cleanup_error := Some error);
          let bridge =
            Runtime_official_client_mcp_http.start
              ~sw
              ~net:(Eio.Stdenv.net env)
              ~secure_random:(Eio.Stdenv.secure_random env)
              ~server_name:"masc"
              ~tool_specs:(fun () -> List.map tool_spec dynamic_tools)
              ~call_tool:(fun ~name ~call_id ~arguments ->
                find_tool dynamic_tools name
                |> Option.map (fun (tool : Host.dynamic_tool) ->
                  tool.call ~call_id arguments |> tool_result))
              ()
          in
          let* () =
            Runtime_antigravity_home.publish_mcp_config
              home
              (Runtime_official_client_mcp_http.mcp_config_json bridge)
            |> Result.map_error (fun error ->
              recovery_failure := Session_store.State_persistence_failed;
              home_error_to_core_error error)
          in
          Runtime_antigravity.run_turn
            ~conversation_mode
            ~home_dir:(Runtime_antigravity_home.home_dir home)
            ~mgr:process_mgr
            ~clock
            ~cwd:process_cwd
            ~on_conversation_ready:(fun ~conversation_id ->
              let* () =
                update_session "active transition" (fun expected ->
                  Session_store.mark_active
                    ~base_path
                    ~keeper_name
                    ~expected
                    ~session_id:conversation_id
                    ~updated_at:(Time_compat.now ()))
              in
              update_session "turn-starting transition" (fun expected ->
                Session_store.mark_turn_starting
                  ~base_path
                  ~keeper_name
                  ~expected
                  ~session_id:conversation_id
                  ~updated_at:(Time_compat.now ())))
            client_config
            ~prompt
          |> Result.map_error (fun error ->
            recovery_failure := recovery_failure_of_runtime_error error;
            runtime_error_to_core_error error))
      in
      match !cleanup_error with
      | None -> turn_result
      | Some error ->
        recovery_failure := Session_store.State_persistence_failed;
        Error (home_error_to_core_error error)
    in
    let turn_result =
      try
        match run_client () with
        | Error error -> Error error
        | Ok turn ->
          recovery_failure := Session_store.Protocol_failed;
          let* () =
            if Bool.equal is_resume turn.resumed
            then Ok ()
            else Error (internal_error "Antigravity resumed flag differs from durable plan")
          in
          let* () =
            if turn.num_turns = turn_count
            then Ok ()
            else
              Error
                (internal_error
                   (Printf.sprintf
                      "Antigravity reported turn %d; durable session expected %d"
                      turn.num_turns
                      turn_count))
          in
          let turn_id =
            provider_turn_identity
              ~conversation_id:turn.conversation_id
              ~num_turns:turn.num_turns
          in
          let* () =
            update_session "turn identity transition" (fun expected ->
              Session_store.mark_turn_started
                ~base_path
                ~keeper_name
                ~expected
                ~session_id:turn.conversation_id
                ~turn_id
                ~updated_at:(Time_compat.now ()))
            |> Result.map_error internal_error
          in
          recovery_failure := Session_store.Host_hook_failed;
          let* () =
            match !terminal_error with
            | None -> Ok ()
            | Some detail -> Error (internal_error detail)
          in
          let latency_ms = Int.of_float ((Time_compat.now () -. started_at) *. 1000.0) in
          let usage : Agent_core.Types.api_usage =
            { input_tokens = turn.usage.input_tokens
            ; output_tokens = turn.usage.output_tokens
            ; cache_creation_input_tokens = 0
            ; cache_read_input_tokens = turn.usage.cache_read_tokens
            ; cost_usd = None
            }
          in
          let response =
            { Agent_core.Types.id = turn_id
            ; model = turn.model
            ; stop_reason = EndTurn
            ; content = [ Text turn.text ]
            ; usage = Some usage
            ; telemetry =
                Some
                  { Agent_core.Types.default_inference_telemetry with
                    request_latency_ms = Some latency_ms
                  ; canonical_model_id = Some turn.model
                  }
            }
          in
          let* () =
            match
              Host.invoke_turn_hook
                ~keeper_name
                ~turn_count
                ~hook_name:"after_turn"
                hooks.after_turn
                (Agent_core.Hooks.AfterTurn { turn = turn_count; response })
            with
            | Continue -> Ok ()
            | HookFailed { stage; detail } ->
              Error (Host.hook_error ~runtime_label ~hook_name:"after_turn" ~stage detail)
            | decision ->
              Error (Host.illegal_hook_decision ~runtime_label ~hook_name:"after_turn" decision)
          in
          let* () =
            match
              Host.invoke_turn_hook
                ~keeper_name
                ~turn_count
                ~hook_name:"on_stop"
                hooks.on_stop
                (Agent_core.Hooks.OnStop { reason = response.stop_reason; response })
            with
            | Continue -> Ok ()
            | HookFailed { stage; detail } ->
              Error (Host.hook_error ~runtime_label ~hook_name:"on_stop" ~stage detail)
            | decision ->
              Error (Host.illegal_hook_decision ~runtime_label ~hook_name:"on_stop" decision)
          in
          recovery_failure := Session_store.State_persistence_failed;
          let* () =
            Session_store.settle
              ~base_path
              ~keeper_name
              ~expected:!session_state
              ~session_id:turn.conversation_id
              ~turn_id
              ~updated_at:(Time_compat.now ())
            |> Result.map (fun settled -> session_state := settled)
            |> Result.map_error (fun detail ->
              internal_error ("Antigravity session settlement failed: " ^ detail))
          in
          let capture, _metrics =
            Runtime_observation.runtime_metrics_for_candidates ~candidate_count:1 ()
          in
          Runtime_observation.record_attempt_terminal
            capture
            ~model_id:turn.model
            ~latency_ms:(Some latency_ms)
            ~error:None;
          let runtime_observation =
            Runtime_observation.runtime_observation_with_metrics
              ~runtime_id
              ~strategy:"official_client_runtime"
              ~configured_labels:
                [ "antigravity_cli"
                ; "execution_mode=plan"
                ; "sandbox=true"
                ; "mcp_owner=masc"
                ; Printf.sprintf "tool_steps=%d" turn.tool_steps
                ; Printf.sprintf "tool_errors=%d" turn.tool_errors
                ; Printf.sprintf "resumed=%b" turn.resumed
                ]
              ~candidate_count:1
              ~selected_model_raw:(Some turn.model)
              ~capture
              ~attempt_details_source:"antigravity_cli"
              ~agent_core_internal_runtime_allowed:false
              ()
          in
          Ok
            { Runtime_agent.response
            ; checkpoint = None
            ; session_id = turn.conversation_id
            ; turns = turn_count
            ; trace_ref = None
            ; run_validation = None
            ; runtime_observation = Some runtime_observation
            ; stop_reason = Completed
            }
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
        let detail = "Antigravity turn cancelled: " ^ Printexc.to_string exn in
        (match Eio.Cancel.protect (fun () -> settle_failed_claim detail) with
         | Ok () -> ()
         | Error recovery_detail ->
           Log.Keeper.error
             ~keeper_name
             "Antigravity cancellation recovery persistence failed: %s"
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
                  "Antigravity turn failed and recovery persistence also failed: original=%s recovery=%s"
                  original_detail
                  recovery_detail))))
;;

let run ~runtime_id ~keeper_name ~base_path ~goal ~goal_blocks ~system_prompt
    ~tools ~initial_messages ~model_input_projection ~hooks ~context_injector
    ~context ~event_bus ~raw_trace ~config =
  Host.with_run_lifecycle_events ~event_bus ~keeper_name (fun () ->
    run_without_lifecycle
      ~runtime_id
      ~keeper_name
      ~base_path
      ~goal
      ~goal_blocks
      ~system_prompt
      ~tools
      ~initial_messages
      ~model_input_projection
      ~hooks
      ~context_injector
      ~context
      ~event_bus
      ~raw_trace
      ~config)
;;

module For_testing = struct
  let fit_history_to_budget = fit_history_to_budget
end
