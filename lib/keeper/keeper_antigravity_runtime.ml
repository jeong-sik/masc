open Result.Syntax

module Host = Keeper_official_client_host
module Session_store = Keeper_official_client_session_store

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; effect_disposition : Keeper_provider_attempt_effect.t
  }

let runtime_label = "Antigravity"

let config_error = Keeper_official_client_host.config_error
let internal_error = Keeper_official_client_host.internal_error

let runtime_error_to_core_error = function
  | Runtime_antigravity.Invalid_config detail ->
    config_error ~field:"antigravity_cli" detail
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
  | Runtime_antigravity.State_callback_failed _ ->
    Session_store.State_persistence_failed
  | Runtime_antigravity.Turn_failed _ -> Session_store.Provider_rejected
;;

let home_error_to_core_error error =
  config_error
    ~field:"antigravity_home"
    (Runtime_antigravity_home.error_to_string error)
;;

let history_role_label = function
  | Agent_core.Types.System -> "SYSTEM:\n"
  | Agent_core.Types.User -> "USER:\n"
  | Agent_core.Types.Assistant -> "ASSISTANT:\n"
  | Agent_core.Types.Tool -> "TOOL:\n"
;;

let render_message (message : Agent_core.Types.message) =
  Ok (history_role_label message.role ^ Host.encode_history_message message)
;;

let render_messages messages =
  let rec loop rendered = function
    | [] -> Ok (String.concat "\n\n" (List.rev rendered))
    | message :: rest ->
      let* rendered_message = render_message message in
      loop (rendered_message :: rendered) rest
  in
  loop [] messages
;;

let extra_system_context_messages messages =
  List.filter
    (fun (message : Agent_core.Types.message) ->
      Agent_core.Types.Extra_system_context_provenance.classify message.metadata
      = Agent_core.Types.Extra_system_context_provenance.Present)
    messages
;;

let system_instructions_label = "SYSTEM INSTRUCTIONS:\n"
let current_goal_label = "CURRENT GOAL:\n"
let prompt_section_separator = "\n\n"

let measure_model_input_message_bytes (message : Agent_core.Types.message) =
  String.length (history_role_label message.role)
  + String.length (Host.encode_history_message message)
  + String.length prompt_section_separator
;;

(* The declared per-model [max-prompt-bytes] is the only authority that can
   bound this provider's turn prompt. The reactive shrink contract the other
   official clients rely on has no stimulus here: agy 1.1.12 does not refuse
   an oversized prompt with a typed overflow — it silently truncates the
   stdin payload (11,386,764 bytes sent, 185,751-byte USER_INPUT recorded by
   the client, 2026-08-14) so the goal at the tail never reaches the model,
   and while stalled on the oversized payload its print-mode response
   subscriber is killed ("Publish killing slow subscriber ... stalled for
   5s"), after which the result event reports SUCCESS with an empty
   response. Six of six spawns failed exactly that way on 2026-08-14, each
   parking the session and re-sending the full history to a fresh
   conversation. Windowing the provider-bound history up front to the
   declared capacity is therefore this runtime's admission contract, not a
   second authority over a provider-owned window.

   [prompt_section_framing_reserved_bytes] is derived from the actual label
   literals [prompt_for_turn] concatenates, so a label change cannot silently
   outgrow the reserve. Each history message is charged its actual role label
   plus one separator; charging a separator for the last message too is a
   deliberate conservative byte that keeps the rendered prompt within the
   declared cap without depending on deployment margin. *)
let prompt_section_framing_reserved_bytes =
  String.length system_instructions_label
  + String.length current_goal_label
  + (2 * String.length prompt_section_separator)
;;

(* The source projection runs first: the one production source appends a
   bounded typed Gate replay reference (keeper_agent_run.ml), and on this
   lane the window is the only authority over the transmitted bytes — there
   is no provider refusal to catch an append that lands after the cut, so
   the window must see everything that ships. The appended reference is the
   newest material and survives the tail window. *)
let bounded_history_projection ~capacity_bytes ~reserved_bytes
    ?on_model_input_window_observation source_projection
  : Agent_core.Agent.model_input_projection
  =
  fun messages ->
  let* messages =
    match source_projection with
    | None -> Ok messages
    | Some project -> project messages
  in
  let history_atom_count = List.length messages in
  Domain_pool_ref.submit_cpu_or_inline (fun () ->
    match
      (* [project_with_drop] rather than [project]: the same cut, keeping the
         counts instead of discarding them. The Agent Core path publishes this
         reading; discarding it here wrote every Antigravity turn record with
         no window and no input composition, which is what [/context] reads. *)
      Runtime_model_input_tail_window.project_with_drop
        ~allow_empty_history:true
        ~measure_message_bytes:measure_model_input_message_bytes
        ~capacity_bytes
        ~reserved_bytes
        messages
    with
    | Ok projection ->
      Option.iter
        (fun observe ->
           observe
             (Runtime_model_input_tail_window.observe
                ~history_atom_count
                projection))
        on_model_input_window_observation;
      Ok projection.Runtime_model_input_tail_window.messages
    | Error error ->
      Error (Runtime_model_input_tail_window.budget_error_to_core_error error))
;;

let capacity_bounded_model_input_projection ~declared_max_prompt_bytes
    ~system_prompt ~goal ?on_model_input_window_observation source_projection
  =
  match declared_max_prompt_bytes with
  (* [None] keeps passing the source through unchanged, as the interface
     says. A runtime that declares no cap cuts nothing, so there is no window
     reading to report and inventing one would claim a measurement that was
     never taken. *)
  | None -> Ok source_projection
  | Some capacity_bytes ->
    let reserved_bytes =
      String.length system_prompt
      + String.length goal
      + prompt_section_framing_reserved_bytes
    in
    if reserved_bytes >= capacity_bytes
    then
      Error
        (config_error
           ~field:"max_prompt_bytes"
           (Printf.sprintf
              "Antigravity fixed prompt sections (system prompt and goal) measure %d bytes, at or above the declared max-prompt-bytes %d; no history window can fit"
              reserved_bytes
              capacity_bytes))
    else
      Ok
        (Some
           (bounded_history_projection
              ~capacity_bytes
              ~reserved_bytes
              ?on_model_input_window_observation
              source_projection))
;;

let prompt_for_turn ~is_resume ~goal (prepared : Host.prepared_turn) =
  if is_resume
  then (
    (* The provider conversation already owns the static system prompt and
       seeded history. The hook context is turn-local, though, so dropping its
       typed carrier on resume changes provider meaning. Prefix only that
       provenance-marked System material and keep the legacy goal bytes exact
       when no dynamic context was supplied. *)
    let* context =
      prepared.messages |> extra_system_context_messages |> render_messages
    in
    match String_util.trim_nonempty context with
    | None -> Ok goal
    | Some context -> Ok (context ^ prompt_section_separator ^ goal))
  else
    let* history = render_messages prepared.messages in
    Ok
      ([ String_util.trim_nonempty prepared.system_prompt
         |> Option.map (fun value -> system_instructions_label ^ value)
      ; String_util.trim_nonempty history
      ; Some (current_goal_label ^ goal)
      ]
      |> List.filter_map Fun.id
      |> String.concat prompt_section_separator)
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

let antigravity_dynamic_tool ~observe_effect_attempted (tool : Host.dynamic_tool) =
  { tool with
    call =
      (fun ~call_id input ->
        (* Close the outer same-turn retry boundary before entering user/tool
           code. The handler may commit and then raise or be cancelled, so
           observing only its returned value would reopen a duplicate-effect
           window. Process spawn and provider generation alone do not produce
           a MASC product effect. *)
        observe_effect_attempted ();
        tool.call ~call_id input)
  }
;;

let find_tool tools name =
  List.find_opt (fun (tool : Host.dynamic_tool) -> String.equal tool.name name) tools
;;

let provider_turn_identity ~conversation_id ~num_turns =
  Printf.sprintf "%s:ordinal:%d" conversation_id num_turns
;;

type stream_projection =
  { on_runtime_event : Runtime_antigravity.stream_event -> unit
  ; on_tool_started :
      call_id:string -> tool_name:string -> arguments:Yojson.Safe.t -> unit
  ; on_tool_finished : call_id:string -> unit
  }

let stream_projection ~keeper_name ~raw_trace_run ~turn_count ~on_native_action on_event =
    let emit event = Option.iter (fun callback -> callback event) on_event in
    let next_tool_index = ref 1 in
    let tool_indexes = Hashtbl.create 8 in
    let native_tool_indexes = Hashtbl.create 8 in
    let emit event =
      try emit event with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.Runtime_agent.warn
          "Antigravity Keeper stream callback raised (error=%s)"
          (Printexc.to_string exn)
    in
    { on_runtime_event =
        (function
          | Runtime_antigravity.Turn_started { conversation_id; model } ->
            emit
              (Agent_core.Types.MessageStart
                 { id = provider_turn_identity ~conversation_id ~num_turns:turn_count
                 ; model
                 ; usage = None
                 })
          | Runtime_antigravity.Text_delta text ->
            emit
              (Agent_core.Types.ContentBlockDelta
                 { index = 0; delta = Agent_core.Types.TextDelta text })
          | Runtime_antigravity.Native_tool_started observation ->
            Option.iter
              (fun observe -> Runtime_native_tools.observe_exact_action ~official_turn:turn_count ~observe observation)
              on_native_action;
            Host.record_raw_native_tool
              ~keeper_name
              ~raw_trace_run
              ~phase:`Started
              observation;
            let index = !next_tool_index in
            incr next_tool_index;
            Option.iter
              (fun identity -> Hashtbl.replace native_tool_indexes identity index)
              observation.identity;
            emit
              (Agent_core.Types.ContentBlockStart
                 { index
                 ; content_type = Runtime_native_tools.stream_content_type
                 ; tool_id = Runtime_native_tools.call_id observation
                 ; tool_name = observation.tool_name
                 })
          | Runtime_antigravity.Native_tool_finished observation ->
            Host.record_raw_native_tool
              ~keeper_name
              ~raw_trace_run
              ~phase:`Finished
              observation;
            Option.iter
              (fun identity ->
                 Option.iter
                   (fun index ->
                      Hashtbl.remove native_tool_indexes identity;
                      emit (Agent_core.Types.ContentBlockStop { index }))
                   (Hashtbl.find_opt native_tool_indexes identity))
              observation.identity
          | Runtime_antigravity.Turn_finished { text = _ } ->
            emit
              (Agent_core.Types.MessageDelta
                 { stop_reason = Some Agent_core.Types.EndTurn; usage = None });
            emit Agent_core.Types.MessageStop)
    ; on_tool_started =
        (fun ~call_id ~tool_name ~arguments ->
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
               }))
    ; on_tool_finished =
        (fun ~call_id ->
          Option.iter
            (fun index ->
               Hashtbl.remove tool_indexes call_id;
               emit (Agent_core.Types.ContentBlockStop { index }))
            (Hashtbl.find_opt tool_indexes call_id))
    }
;;

let run_without_lifecycle ~runtime_id ~keeper_name
    ~on_model_input_window_observation
    ~pre_tool_rejects ~base_path ~goal ~goal_blocks
    ~system_prompt ~tools ~initial_messages ~model_input_projection ~hooks
    ~context_injector ~context ~terminal_effect_state ~event_bus ~raw_trace ~on_event
    ~observe_effect_attempted
    ~on_official_client_result_handoff ~on_native_action
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
    let* native_posture =
      Host.resolve_native_posture
        ~base_path
        ~keeper_name
        ~client_label:"Antigravity"
        ~default:Runtime_native_tools.antigravity_default
        ~none_supported:false
    in
    let tool_surface_sha256 =
      Session_store.tool_surface_sha256 ~native_posture tools
    in
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
    let* goal =
      match goal_blocks with
      | None -> Ok goal
      | Some blocks -> Host.text_of_blocks ~runtime_label ~field:"goal_blocks" blocks
    in
    let declared_max_prompt_bytes =
      Runtime_inference.resolve_max_prompt_bytes ~runtime_id
    in
    let* model_input_projection =
      capacity_bounded_model_input_projection
        ~declared_max_prompt_bytes
        ~system_prompt
        ~goal
        ?on_model_input_window_observation
        model_input_projection
    in
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
    let* prompt = prompt_for_turn ~is_resume ~goal prepared in
    (* Recording the half this process controls, mirroring the Codex and
       Claude Code composition lines: an oversized prompt was invisible until
       the client's own log showed promptLength=11,386,764 (2026-08-14). *)
    Log.Keeper.info
      ~keeper_name
      "%s turn composition: mode=%s prompt_bytes=%d system_prompt_bytes=%d \
       goal_bytes=%d declared_max_prompt_bytes=%s"
      runtime_label
      (if is_resume then "resume" else "start")
      (String.length prompt)
      (String.length prepared.system_prompt)
      (String.length goal)
      (match declared_max_prompt_bytes with
       | None -> "undeclared"
       | Some bytes -> string_of_int bytes);
    let terminal_error = ref None in
    let* dynamic_tools =
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
        ~on_result_handoff:on_official_client_result_handoff
        ()
    in
    let runtime_root = Common.masc_dir_from_base_path ~base_path in
    let* home =
      Runtime_antigravity_home.prepare
        ~runtime_root
        ~owner_leaf:keeper_name
        ~oauth_source:config.oauth_source
      |> Result.map_error home_error_to_core_error
    in
    (* Only the states that changed something or explain a later stall are
       worth a line; [Present] is every turn after the first. *)
    (match Runtime_antigravity_home.keychain_state home with
     | Runtime_antigravity_home.Present | Runtime_antigravity_home.Unsupported -> ()
     | Runtime_antigravity_home.Provisioned ->
       Log.Keeper.info
         ~keeper_name
         "%s login keychain provisioned for the isolated HOME"
         runtime_label
     | Runtime_antigravity_home.Failed _ as state ->
       Log.Keeper.warn
         ~keeper_name
         "%s login keychain unavailable (%s) — a token refresh will stall ~5s \
          and may raise an operator dialog"
         runtime_label
         (Runtime_antigravity_home.keychain_state_to_string state));
    let client_config : Runtime_antigravity.config =
      { cli_path = config.cli_path
      ; cwd = base_path
      ; add_dirs = config.add_dirs
      ; model = config.model
      ; agent = config.agent
      ; effort = config.effort
      ; (* [Plan] holds the built-in tools to observation; [Accept_edits]
           opens their effects and is admitted only for Yolo keepers
           (RFC-0390). The sandbox stays on in both postures — it is a
           separate safety floor, not a tool-availability knob. *)
        execution_mode =
          (match native_posture with
           | Runtime_native_tools.Native_full -> Runtime_antigravity.Accept_edits
           | Runtime_native_tools.Native_none | Runtime_native_tools.Native_read
             -> Runtime_antigravity.Plan)
      ; sandbox = true
      ; disable_slash_commands = true
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
      ; wall_clock_ceiling_s =
          Runtime_inference.resolve_wall_clock_ceiling_s ~runtime_id
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
        ~on_result_handoff:on_official_client_result_handoff
        ()
    in
    let dynamic_tools =
      List.map (antigravity_dynamic_tool ~observe_effect_attempted) dynamic_tools
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
      let stream =
        stream_projection ~keeper_name ~raw_trace_run ~turn_count ~on_native_action on_event
      in
    let settle_host_stop stop =
      match (!session_state).Session_store.phase with
      | Turn_inflight { session_id; turn_id; _ } ->
        let turn_id =
          Option.value
            turn_id
            ~default:(provider_turn_identity ~conversation_id:session_id ~num_turns:turn_count)
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
          (* The phase carries six constructors and the entry guard admits
             three, so this arm is reachable by [Start] and [Active] as well as
             by anything a concurrent transition leaves behind. It was
             [assert false]: a claim of unreachability the compiler cannot
             check, in a chain that already returns [Error]. Returning one
             loses nothing the assert provided and does not take the process
             with it -- masc#28983's shape, where a wildcard promise became an
             Assert_failure at run time. *)
          | _, other ->
            let phase_name =
              match other with
              | Session_store.Ready -> "Ready"
              | Session_store.Start _ -> "Start"
              | Session_store.Active _ -> "Active"
              | Session_store.Turn_inflight _ -> "Turn_inflight"
              | Session_store.Recovery_required _ -> "Recovery_required"
              | Session_store.Settled _ -> "Settled"
            in
            Error
              (internal_error
                 (Printf.sprintf
                    "host-stop turn identity: expected Turn_inflight, phase is %s"
                    phase_name))
        in
        let projected =
          Host.host_stop_result
            ~runtime_id
            ~model:config.model
            ~session_id
            ~turn_id
            ~turns_used:turn_count
            ~latency_ms:
              (Some (Int.of_float ((Time_compat.now () -. started_at) *. 1000.0)))
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
        let* settled =
          Session_store.settle
            ~base_path
            ~keeper_name
            ~expected:!session_state
            ~session_id
            ~turn_id
            ~updated_at:(Time_compat.now ())
          |> Result.map_error (fun detail ->
            internal_error ("Antigravity host-stop settlement failed: " ^ detail))
        in
        session_state := settled;
        projected
      | Ready | Start _ | Active _ | Recovery_required _ | Settled _ ->
        Error
          (internal_error
             "Antigravity host stop arrived without an admitted provider turn")
    in
    let run_client () =
      let cleanup_error = ref None in
      let turn_result =
        Eio.Switch.run (fun sw ->
          let abort_turn, resolve_abort_turn = Eio.Promise.create () in
          let abort_turn_resolved = Atomic.make false in
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
                  stream.on_tool_started ~call_id ~tool_name:name ~arguments;
                  Fun.protect
                    ~finally:(fun () -> stream.on_tool_finished ~call_id)
                    (fun () ->
                      let result = tool.call ~call_id arguments in
                      { Runtime_official_client_mcp_http.outcome = tool_result result
                      ; after_response_sent =
                          (fun () ->
                             Option.iter
                               (fun detail ->
                                  if
                                    Atomic.compare_and_set
                                      abort_turn_resolved
                                      false
                                      true
                                  then
                                    Eio.Promise.resolve
                                      resolve_abort_turn
                                      detail)
                               result.abort_turn)
                      })))
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
          match
            Eio.Fiber.first
              (fun () ->
                 `Runtime
                   (Runtime_antigravity.run_turn
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
                      ~on_stream_event:stream.on_runtime_event
                      client_config
                      ~prompt))
              (fun () -> `Abort (Eio.Promise.await abort_turn))
          with
          | `Runtime client_result ->
            client_result
            |> Result.map (fun turn -> `Completed turn)
            |> Result.map_error (fun error ->
              recovery_failure := recovery_failure_of_runtime_error error;
              runtime_error_to_core_error error)
          | `Abort stop -> Ok (`Stopped stop))
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
        | Ok (`Stopped stop) ->
          recovery_failure := Session_store.Host_hook_failed;
          (match !terminal_error with
           | Some detail -> Error (internal_error detail)
           | None -> settle_host_stop stop)
        | Ok (`Completed turn) ->
          recovery_failure := Session_store.Protocol_failed;
          (match turn.trajectory_error with
           | None -> ()
           | Some detail ->
             Log.Keeper.warn
               ~keeper_name
               "antigravity turn completed with %d tool error step(s); last step error: %s"
               turn.tool_errors
               detail);
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
                ~turn_count:turn.num_turns
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
          (* The CLI reports an exclusive prompt count: [parse_usage] accepts a
             frame only when total_tokens = input_tokens + output_tokens, so
             the cache it read is not in either. [api_usage.input_tokens] is
             the inclusive total, so the components go through the shared
             constructor -- assembling the record here put an exclusive count
             in an inclusive slot, and every cache hit went missing from
             context occupancy. The keeper's claude_code sibling has always
             built through it. *)
          let usage =
            Agent_core.Llm_provider.Backend_anthropic.usage_of_wire_counts
              ~input_tokens:turn.usage.input_tokens
              ~output_tokens:turn.usage.output_tokens
              ~cache_creation_input_tokens:0
              ~cache_read_input_tokens:turn.usage.cache_read_tokens
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
            Host.invoke_turn_completion_hooks
              ~runtime_label
              ~keeper_name
              ~turn_count:turn.num_turns
              ~hooks
              response
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
              ~attempt_details_source:"antigravity_cli"
              ~agent_core_internal_runtime_allowed:false
              ~usage_scope:Runtime_usage_scope.Conversation_cumulative
              ()
          in
          Ok
            { Runtime_agent.response
            ; checkpoint = None
            ; session_id = turn.conversation_id
            ; turns = turn.num_turns
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

let run ~runtime_id ~keeper_name ~pre_tool_rejects ~base_path ~goal ~goal_blocks ~system_prompt
    ~tools ~initial_messages ~model_input_projection ~hooks ~context_injector
    ~context
    ?(terminal_effect_state = fun () -> Keeper_tools_agent_core.Terminal_effect_open)
    ?on_model_input_window_observation
    ?(on_official_client_result_handoff = fun ~invocation:_ ~content:_ -> ())
    ?on_native_action
    ~event_bus ~raw_trace ~on_event ~config () =
  let effect_disposition =
    Atomic.make Keeper_provider_attempt_effect.No_effect_observed
  in
  let observe_effect_attempted () =
    Atomic.set effect_disposition Keeper_provider_attempt_effect.Effect_attempted
  in
  let result =
    Host.with_run_lifecycle_events ~event_bus ~keeper_name (fun () ->
      run_without_lifecycle
        ~runtime_id
        ~keeper_name
        ~on_model_input_window_observation
    ~pre_tool_rejects
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
        ~terminal_effect_state
        ~on_official_client_result_handoff ~on_native_action
        ~event_bus
        ~raw_trace
        ~on_event
        ~observe_effect_attempted
        ~config)
  in
  { result; effect_disposition = Atomic.get effect_disposition }
;;

module For_testing = struct
  let capacity_bounded_model_input_projection =
    capacity_bounded_model_input_projection
  ;;

  let start_prompt_bytes ~system_prompt ~goal messages =
    let prepared : Host.prepared_turn =
      { messages; system_prompt; tools = []; reasoning_effort = None }
    in
    Result.map String.length (prompt_for_turn ~is_resume:false ~goal prepared)
  ;;

  (* One byte more than this is the smallest admissible declared capacity.
     This is not the rendered empty-history prompt: the reserve charges both
     separators (the with-history worst case), while an empty-history render
     joins its two sections with one. *)
  let reserved_prompt_bytes ~system_prompt ~goal =
    String.length system_prompt
    + String.length goal
    + prompt_section_framing_reserved_bytes
  ;;
end
