open Result.Syntax

module Host = Keeper_official_client_host
module Session_store = Keeper_official_client_session_store

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; settled_session : Keeper_official_client_session_store.t option
  ; effect_disposition : Keeper_provider_attempt_effect.t
  }

let runtime_label = "Muse"

let config_error = Keeper_official_client_host.config_error
let internal_error = Keeper_official_client_host.internal_error

let runtime_error_to_core_error = function
  | Runtime_muse.Invalid_config detail ->
    config_error ~field:"muse_cli" detail
  | Runtime_muse.Turn_failed { terminal; reason; usage = _ } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderReportedError
         { provider = "muse_cli"
         ; error_type = Some terminal
         ; detail =
             (match reason with
              | Some reason -> reason
              | None -> "the Muse turn ended as " ^ terminal)
         })
  | Runtime_muse.Timeout seconds ->
    Agent_core.Error.Api
      (Agent_core.Retry.Timeout
         { message = Printf.sprintf "Muse turn timed out after %.3fs" seconds
         ; phase = None
         })
  | Runtime_muse.Spawn_failed detail ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderUnavailable { provider = "muse_cli"; detail })
  | Runtime_muse.Process_exited { detail; turn_admitted = _ } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderUnavailable { provider = "muse_cli"; detail })
  | Runtime_muse.Protocol_error { stage; detail } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ParseError
         { detail = Printf.sprintf "%s: %s" stage detail })
;;

let recovery_failure_of_runtime_error = function
  | Runtime_muse.Spawn_failed _ -> Session_store.Transient_spawn_failed
  | Runtime_muse.Process_exited _ | Runtime_muse.Timeout _ ->
    Session_store.Transport_interrupted
  | Runtime_muse.Invalid_config _ | Runtime_muse.Protocol_error _ ->
    Session_store.Protocol_failed
  | Runtime_muse.Turn_failed _ -> Session_store.Provider_rejected
;;

let render_message (message : Agent_core.Types.message) =
  Ok (Host.history_role_label message.role ^ Host.encode_history_message message)
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

let prompt_section_separator = "\n\n"
let system_instructions_label = "System instructions:\n"
let current_goal_label = "Current goal:\n"

let prompt_for_turn ~is_resume ~goal (prepared : Host.prepared_turn) =
  if is_resume
  then
    (* The provider session already owns the static system prompt and seeded
       history. The hook context is turn-local, though, so dropping its typed
       carrier on resume changes provider meaning. *)
    Ok (Host.resume_prompt ~goal prepared.messages)
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

let provider_turn_identity ~session_id ~num_turns =
  Printf.sprintf "%s:ordinal:%d" session_id num_turns
;;

(* The CLI reports OpenAI-convention counts over its Model API: the input
   count includes the cached prefix and the output count includes reasoning,
   so both copy across and the cache field fills the canonical record's
   cache slot, the same reading Backend_openai_parse makes of the API wire. *)
let api_usage_of_muse_usage (usage : Runtime_muse.token_usage) : Agent_core.Types.api_usage =
  { input_tokens = usage.Runtime_muse.input_tokens
  ; output_tokens = usage.Runtime_muse.output_tokens
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = usage.Runtime_muse.cached_tokens
  ; cost_usd = None
  }
;;

type stream_projection = { on_runtime_event : Runtime_muse.stream_event -> unit }

let stream_projection ~turn_count ~model ~position ~on_usage_report on_event =
  let emit event = Option.iter (fun callback -> callback event) on_event in
  let emit event =
    try emit event with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Log.Runtime_agent.warn
        "Muse Keeper stream callback raised (error=%s)"
        (Printexc.to_string exn)
  in
  { on_runtime_event =
      (function
        | Runtime_muse.Turn_started { session_id; turn_id = _ } ->
          emit
            (Agent_core.Types.MessageStart
               { id = provider_turn_identity ~session_id ~num_turns:turn_count
               ; model
               ; usage = None
               })
        | Runtime_muse.Text_delta text ->
          emit
            (Agent_core.Types.ContentBlockDelta
               { index = 0; delta = Agent_core.Types.TextDelta text })
        | Runtime_muse.Usage_reported { session_id; usage } ->
          Option.iter
            (fun report ->
               report
                 { Keeper_client_usage_report.official_turn = turn_count
                 ; response_id = provider_turn_identity ~session_id ~num_turns:turn_count
                 ; model
                 ; conversation_id = session_id
                 ; position
                 ; usage_scope = Runtime_usage_scope.Turn_total
                 ; count =
                     Keeper_client_usage_report.Running_count
                       (api_usage_of_muse_usage usage)
                 ; vendor_total_tokens = None
                 })
            on_usage_report
        | Runtime_muse.Turn_finished { text = _ } ->
          emit
            (Agent_core.Types.MessageDelta
               { stop_reason = Some Agent_core.Types.EndTurn; usage = None });
          emit Agent_core.Types.MessageStop)
  }
;;

(* The CLI takes image files, the goal holds base64 bytes. One file per
   image, 0600, removed when the turn that consumed it finishes. *)
let extension_of_media_type = function
  | "image/png" -> Some ".png"
  | "image/jpeg" -> Some ".jpg"
  | "image/gif" -> Some ".gif"
  | "image/webp" -> Some ".webp"
  | _ -> None
;;

let image_file_of_block (image : Host.image_block) =
  let* extension =
    match extension_of_media_type image.Host.media_type with
    | Some extension -> Ok extension
    | None ->
      Error
        (config_error
           ~field:"goal_blocks"
           (Printf.sprintf
              "Muse cannot carry an image of media type %S; expected image/png, \
               image/jpeg, image/gif or image/webp"
              image.Host.media_type))
  in
  let* bytes =
    match Base64.decode image.Host.base64_data with
    | Ok bytes -> Ok bytes
    | Error (`Msg detail) ->
      Error (config_error ~field:"goal_blocks" ("Muse image is not base64: " ^ detail))
  in
  let path, output =
    Filename.open_temp_file ~perms:0o600 ~mode:[ Open_binary ] "masc-muse-image-" extension
  in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () ->
      output_string output bytes;
      close_out output;
      let absolute =
        if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
      in
      Ok ({ Runtime_muse.path = absolute } : Runtime_muse.image_input))
;;

let muse_images_of_goal_blocks blocks =
  let* _, images =
    Host.text_and_images_of_blocks ~runtime_label ~field:"goal_blocks" blocks
  in
  let rec loop written = function
    | [] -> Ok (List.rev written)
    | image :: rest ->
      let* input = image_file_of_block image in
      loop (input :: written) rest
  in
  loop [] images
;;

let remove_image_files (images : Runtime_muse.image_input list) =
  List.iter
    (fun (image : Runtime_muse.image_input) ->
      try Sys.remove image.Runtime_muse.path with
      | Sys_error detail ->
        Log.Runtime_agent.warn "Muse image file cleanup failed: %s" detail)
    images
;;

let run_without_lifecycle ~official_task_reference ~accepts_image_input ~on_session_settled
    ~required_native_posture ~official_client_continuation ~runtime_id ~keeper_name
    ~pre_tool_rejects:_ ~base_path ~goal ~goal_blocks ~system_prompt ~tools ~initial_messages
    ~model_input_projection ~on_transmitted_model_input ~hooks ~context_injector:_
    ~context:_ ~terminal_effect_state:_ ~on_model_input_window_observation:_
    ~carried_front_seed:_ ~librarian_front:_ ~on_carried_front:_ ~turn_start:_
    ~on_official_client_tool_boundary:_ ~on_official_client_result_handoff:_
    ~on_native_action:_ ~on_usage_report ~event_bus:_ ~raw_trace ~on_event
    ~(config : Runtime_execution.muse_cli) =
  match Eio_context.get_env_opt (), Eio_context.get_clock_opt () with
  | None, _ ->
    Error
      (config_error
         ~field:"eio_env"
         "Muse runtime requires the initialized Eio standard environment")
  | _, None ->
    Error
      (config_error ~field:"eio_clock" "Muse runtime requires the initialized Eio clock")
  | Some env, Some clock ->
    let hooks =
      match hooks with Some hooks -> hooks | None -> Agent_core.Hooks.empty
    in
    let owner_epoch = Session_store.process_epoch () in
    let* stored_session =
      Session_store.load ~base_path ~keeper_name
      |> Result.map_error (fun detail ->
        internal_error ("Muse session binding load failed: " ^ detail))
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
        ~client_kind:Session_store.Muse
        ~runtime_id
      |> Result.map_error Session_store.core_error_of_claim_error
    in
    let* native_posture =
      Host.resolve_native_posture
        ~posture_source:
          (Runtime_native_tools.posture_source_of_required required_native_posture)
        ~base_path
        ~keeper_name
        ~client_label:"Muse"
        ~default:Runtime_native_tools.muse_default
        ~none_supported:
          (Runtime_execution.supports_native_none (Runtime_execution.Muse_cli config))
    in
    let tool_surface_sha256 =
      Session_store.tool_surface_sha256 ~native_posture tools
    in
    let* () =
      match official_client_continuation with
      | None -> Ok ()
      | Some checkpoint ->
        Keeper_official_client_session_store.validate_continuation ~checkpoint
          ~expected:stored_session ~client_kind:Session_store.Muse ~runtime_id ~tool_surface_sha256
        |> Result.map_error (config_error ~field:"official_client_session.gate_continuation")
    in
    let claim_plan =
      Session_store.reconcile_tool_surface claim_plan ~tool_surface_sha256
    in
    (* This CLI offers no replaceable configuration channel. A vendor session
       that settled against another canonical history or system prompt is
       superseded by a fresh one seeded from the canonical source. *)
    let snapshot =
      `Assoc
        [ "system_prompt", `String system_prompt
        ; ( "messages"
          , `List (List.map Keeper_official_client_context_codec.to_json initial_messages) )
        ]
    in
    let snapshot_sha256 =
      snapshot |> Yojson.Safe.to_string |> Digestif.SHA256.digest_string
      |> Digestif.SHA256.to_hex
    in
    let admission_error reason =
      config_error
        ~field:"official_client_session.context_admission"
        (Session_store.context_admission_error_to_string reason)
    in
    (* A Gate continuation is bound to its original vendor session: completion
       requires that session to settle again, so a fresh one would run the
       effects and then fail. It keeps the refusal, before any dispatch. *)
    let* reconciled_plan =
      match official_client_continuation with
      | Some _ when Option.is_some claim_plan.previous_settlement ->
        Session_store.validate_unchanged_context ~expected:stored_session ~snapshot_sha256
        |> Result.map (fun () -> claim_plan)
        |> Result.map_error admission_error
      | Some _ | None ->
        Ok (Session_store.reconcile_context claim_plan ~expected:stored_session ~snapshot_sha256)
    in
    (match claim_plan.previous_settlement, reconciled_plan.previous_settlement with
     | Some { session_id; _ }, None ->
       Log.Keeper.info
         "muse: keeper=%s vendor session %s did not settle against the current canonical history and system prompt; starting a fresh session"
         keeper_name session_id
     | Some _, Some _ | None, (Some _ | None) -> ());
    let claim_plan = reconciled_plan in
    let conversation_mode =
      match claim_plan.previous_settlement with
      | None -> Runtime_muse.Start
      | Some { session_id; _ } -> Runtime_muse.Resume { session_id }
    in
    let is_resume = Option.is_some claim_plan.previous_settlement in
    let context_frontier : Session_store.context_frontier =
      { snapshot_sha256
      ; message_count = List.length initial_messages
      ; delivery = Canonical_source_guard
      ; acknowledged_turn = None
      }
    in
    let turn_count = claim_plan.turn_count in
    let* goal, goal_images =
      match goal_blocks with
      | None -> Ok (goal, [])
      | Some blocks ->
        let* text, images =
          Host.text_and_images_of_blocks ~runtime_label ~field:"goal_blocks" blocks
        in
        if (not accepts_image_input) && not (List.is_empty images)
        then
          Error
            (config_error
               ~field:"goal_blocks"
               "Muse turn carries goal images but the runtime does not accept image input")
        else Ok (text, images)
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
    (* [prompt_for_turn] renders [prepared.system_prompt] as the
       system-instructions section; [Host.prepare_turn] has already refused a
       blank one, so the section is always present on a start (#33165). *)
    (* This is the prepared attribution, not transmission evidence. The
       runtime emits it only after the child is spawned with its prompt file. *)
    let report_transmitted_input () =
      on_transmitted_model_input
        (if is_resume
         then Host.Held_by_client_session
         else Host.Whole_input_transmitted prepared.messages)
    in
    let* prompt = prompt_for_turn ~is_resume ~goal prepared in
    (* Recording the half this process controls, mirroring the Codex, Claude
       Code and Antigravity composition lines: an oversized prompt was
       invisible until the client's own log showed it. *)
    Log.Keeper.info
      ~keeper_name
      "%s turn composition: mode=%s prompt_bytes=%d system_prompt_bytes=%d goal_bytes=%d"
      runtime_label
      (if is_resume then "resume" else "start")
      (String.length prompt)
      (String.length prepared.system_prompt)
      (String.length goal);
    let* () =
      match official_task_reference with
      | None -> Ok ()
      | Some _ ->
        Error
          (config_error
             ~field:"official_client_session.context_admission"
             "historical_task_reference_unavailable: this client cannot replace task-reference context without replaying it as user input")
    in
    let client_config : Runtime_muse.config =
      { cli_path = config.cli_path
      ; cwd = base_path
      ; model = config.model
      ; reasoning_effort =
          Option.map
            Runtime_muse.effort_of_reasoning_effort
            prepared.Host.reasoning_effort
      ; (* The CLI has no tool-suppression channel: [Never] runs its built-in
           tools unaudited and is admitted only for Yolo keepers (RFC-0390).
           Anything weaker keeps the CLI default, whatever headless does with
           an approval it cannot ask for. *)
        approval_mode =
          (match native_posture with
           | Runtime_native_tools.Native_full -> Runtime_muse.Never
           | Runtime_native_tools.Native_none | Runtime_native_tools.Native_read ->
             Runtime_muse.On_request)
      (* A keeper turn is a conversation, not a schema contract: nothing
         downstream parses its text against a domain schema. *)
      ; output_schema = None
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
    let raw_trace_run =
      Host.start_raw_trace
        ~keeper_name
        ~raw_trace
        ~prompt
        ?model:config.model
        ?reasoning_effort:
          (Option.map
             Runtime_muse.effort_to_string
             client_config.Runtime_muse.reasoning_effort)
        ()
    in
    let* claimed_session =
      Session_store.claim_with_context_frontier
        ~context_frontier:(Some context_frontier)
        ~base_path
        ~keeper_name
        ~expected:stored_session
        ~client_kind:Session_store.Muse
        ~owner_epoch
        ~runtime_id
        ~tool_surface_sha256
        ~updated_at:(Time_compat.now ())
      |> Result.map_error (fun detail ->
        let error = internal_error ("Muse session claim failed: " ^ detail) in
        Host.finish_raw_error ~keeper_name raw_trace_run error;
        error)
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
        Error (Printf.sprintf "Muse session %s failed: %s" label detail)
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
      | Session_store.Transient ->
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
      | Session_store.Ambiguous | Session_store.Fatal -> require_recovery detail
    in
    let process_mgr = Posix_spawn_process_mgr.mgr in
    let process_cwd = Eio.Path.(Eio.Stdenv.fs env / base_path) in
    let started_at = Time_compat.now () in
    let model =
      match config.model with
      | Some model -> model
      | None -> "muse"
    in
    let stream =
      stream_projection ~turn_count ~model
        ~position:
          (match conversation_mode with
           | Runtime_muse.Start -> Keeper_usage_resolution.Fresh
           | Runtime_muse.Resume _ -> Keeper_usage_resolution.Resumed)
        ~on_usage_report on_event
    in
    let images_of_goal () =
      let rec loop written = function
        | [] -> Ok (List.rev written)
        | image :: rest ->
          let* input = image_file_of_block image in
          loop (input :: written) rest
      in
      loop [] goal_images
    in
    let run_client images =
      Runtime_muse.run_turn
        ~mgr:process_mgr
        ~clock
        ~cwd:process_cwd
        ~session_mode:conversation_mode
        ~on_prompt_sent:report_transmitted_input
        ~on_session_ready:(fun ~session_id ~turn_id:_ ->
          let (_ : (unit, string) result) =
            Result.bind
              (update_session "active transition" (fun expected ->
                 Session_store.mark_active
                   ~base_path
                   ~keeper_name
                   ~expected
                   ~session_id
                   ~updated_at:(Time_compat.now ())))
              (fun () ->
                update_session "turn-starting transition" (fun expected ->
                  Session_store.mark_turn_starting
                    ~base_path
                    ~keeper_name
                    ~expected
                    ~session_id
                    ~updated_at:(Time_compat.now ())))
          in
          ())
        ~on_stream_event:stream.on_runtime_event
        client_config
        ~prompt
        ~images
      |> Result.map_error (fun error ->
        recovery_failure := recovery_failure_of_runtime_error error;
        runtime_error_to_core_error error)
    in
    let turn_result =
      try
        let* images = images_of_goal () in
        Fun.protect
          ~finally:(fun () -> remove_image_files images)
          (fun () ->
            match run_client images with
            | Error error -> Error error
            | Ok turn ->
              recovery_failure := Session_store.Protocol_failed;
              let turn_id =
                provider_turn_identity ~session_id:turn.session_id ~num_turns:turn_count
              in
              let* () =
                update_session "turn identity transition" (fun expected ->
                  Session_store.mark_turn_started
                    ~base_path
                    ~keeper_name
                    ~expected
                    ~session_id:turn.session_id
                    ~turn_id
                    ~turn_count
                    ~updated_at:(Time_compat.now ()))
                |> Result.map_error internal_error
              in
              recovery_failure := Session_store.Host_hook_failed;
              let latency_ms = Int.of_float ((Time_compat.now () -. started_at) *. 1000.0) in
              let response =
                { Agent_core.Types.id = turn_id
                ; model
                ; stop_reason = Agent_core.Types.EndTurn
                ; content = [ Agent_core.Types.Text turn.text ]
                ; usage = Option.map api_usage_of_muse_usage turn.usage
                ; telemetry =
                    Some
                      { Agent_core.Types.default_inference_telemetry with
                        request_latency_ms = Some latency_ms
                      ; canonical_model_id = Some model
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
                Session_store.settle
                  ~base_path
                  ~keeper_name
                  ~expected:!session_state
                  ~session_id:turn.session_id
                  ~turn_id
                  ~updated_at:(Time_compat.now ())
                |> Result.map (fun settled ->
                  session_state := settled;
                  on_session_settled settled)
                |> Result.map_error (fun detail ->
                  internal_error ("Muse session settlement failed: " ^ detail))
              in
              let capture, _metrics =
                Runtime_observation.runtime_metrics_for_candidates ()
              in
              Runtime_observation.record_attempt_terminal
                capture
                ~model_id:model
                ~latency_ms:(Some latency_ms)
                ~error:None;
              let runtime_observation =
                Runtime_observation.runtime_observation_with_metrics
                  ~runtime_id
                  ~selected_model_raw:(Some model)
                  ~capture
                  ~attempt_details_source:"muse_cli"
                  ~agent_core_internal_runtime_allowed:false
                  ~usage_scope:Runtime_usage_scope.Turn_total
                  ()
              in
              Ok
                { Runtime_agent.response
                ; checkpoint = None
                ; session_id = turn.session_id
                ; session_resumed = Some is_resume
                ; turns = turn_count
                ; trace_ref = None
                ; run_validation = None
                ; runtime_observation = Some runtime_observation
                ; cooperative_boundary = None
                ; stop_reason = Runtime_agent_context.Completed
                })
      with
      | Eio.Cancel.Cancelled _ as exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        recovery_failure
          := (match exn with
              | Eio.Cancel.Cancelled Keeper_owner_signals.Stop_active_child ->
                Session_store.Owner_stopped_turn
              | _ -> Session_store.Transport_interrupted);
        let detail = "Muse turn cancelled: " ^ Printexc.to_string exn in
        (match Eio.Cancel.protect (fun () -> settle_failed_claim detail) with
         | Ok () -> ()
         | Error recovery_detail ->
           Log.Keeper.error
             ~keeper_name
             "Muse cancellation recovery persistence failed: %s"
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
                  "Muse turn failed and recovery persistence also failed: original=%s recovery=%s"
                  original_detail
                  recovery_detail))))
;;

let run ?official_task_reference ~accepts_image_input ?required_native_posture
    ?official_client_continuation ~runtime_id ~keeper_name ~pre_tool_rejects ~base_path ~goal
    ~goal_blocks ~system_prompt ~tools ~initial_messages ~model_input_projection
    ~on_transmitted_model_input ~hooks ~context_injector ~context ?terminal_effect_state
    ?on_model_input_window_observation ?carried_front_seed ?librarian_front ?on_carried_front
    ~turn_start ?on_official_client_tool_boundary ?on_official_client_result_handoff
    ?on_native_action ?on_usage_report ~event_bus ~raw_trace ~on_event ~config () =
  let settled_session = Atomic.make None in
  let on_session_settled value = Atomic.set settled_session (Some value) in
  let result =
    Host.with_run_lifecycle_events ~event_bus ~keeper_name (fun () ->
      run_without_lifecycle ~official_task_reference ~accepts_image_input ~on_session_settled
        ~official_client_continuation ~required_native_posture ~runtime_id ~keeper_name
        ~pre_tool_rejects ~base_path ~goal ~goal_blocks ~system_prompt ~tools ~initial_messages
        ~model_input_projection ~on_transmitted_model_input ~hooks ~context_injector
        ~context ?terminal_effect_state ?on_model_input_window_observation ?carried_front_seed
        ?librarian_front ?on_carried_front ~turn_start ?on_official_client_tool_boundary
        ?on_official_client_result_handoff ?on_native_action ~on_usage_report ~event_bus
        ~raw_trace ~on_event ~config)
  in
  { result
  ; settled_session = Atomic.get settled_session
  ; effect_disposition = Keeper_provider_attempt_effect.No_effect_observed
  }
;;

module For_testing = struct
  let report_stream_usage ~turn_count ~position ~report event =
    (stream_projection
       ~turn_count
       ~model:"test"
       ~position
       ~on_usage_report:(Some report)
       None).on_runtime_event
      event
  ;;

  let start_prompt_bytes ~system_prompt ~goal messages =
    let prepared : Host.prepared_turn =
      { messages; system_prompt; tools = []; reasoning_effort = None }
    in
    Result.map String.length (prompt_for_turn ~is_resume:false ~goal prepared)
  ;;

  let muse_images_of_goal_blocks = muse_images_of_goal_blocks
end
