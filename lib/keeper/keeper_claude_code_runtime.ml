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
   start seed. A runtime that declares max-prompt-bytes starts inside it; one
   that does not starts unbounded and narrows after Claude has explicitly
   rejected the prior view as too large. Waiting for that rejection in both
   cases is what made a declared ceiling cost a full turn to discover. The
   next structural boundary is computed before source projections append
   synthetic evidence, matching the Codex official-client path. *)
(* The cut is the same one [Keeper_turn_driver_try_provider] makes on the
   Agent Core path, and that path reports it: [project_with_drop] returns how
   much of the history survived, [observe] pairs it with what was offered, and
   the turn record carries the pair. Here the same call went through [project],
   which keeps the messages and drops the counts, so every official-client turn
   wrote a record with no window reading and no input composition -- which is
   what [/context] reads. Same measurement, reported instead of discarded. *)
let model_input_projection_for_capacity
    ~capacity_bytes
    ~observed_next_shrink_capacity_bytes
    ~observed_floor_capacity_bytes
    ?on_model_input_window_observation
    source_projection
    messages =
  let history_atom_count = List.length messages in
  let windowed =
    if capacity_bytes = unbounded_model_input_capacity_bytes
    then (
      (* No cut is still a reading: everything offered was carried. Leaving
         this branch silent would put the turn record's absent window back
         for any runtime whose declared cap is unbounded. *)
      Option.iter
        (fun observe ->
           observe
             { Runtime_model_input_tail_window.transmitted_atoms =
                 history_atom_count
             ; total_atoms = history_atom_count
             })
        on_model_input_window_observation;
      Ok messages)
    else
      Domain_pool_ref.submit_cpu_or_inline (fun () ->
        match
          Runtime_model_input_tail_window.project_with_drop
            ~allow_empty_history:true
            ~measure_message_bytes:measure_model_input_message_bytes
            ~capacity_bytes
            ~reserved_bytes:0
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
          Error
            (Runtime_model_input_tail_window.budget_error_to_core_error error))
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

let claude_stream_callback ~keeper_name ~raw_trace_run ~turn_count ~on_native_action on_event =
  match on_event, raw_trace_run, on_native_action with
  | None, None, None -> None
  | _ ->
    let emit event = Option.iter (fun callback -> callback event) on_event in
    let next_tool_index = ref 1 in
    let tool_indexes = Hashtbl.create 8 in
    let native_tool_indexes = Hashtbl.create 8 in
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
        | Runtime_claude_code.Native_tool_started observation ->
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
        | Runtime_claude_code.Native_tool_finished observation ->
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
          emit
            (Agent_core.Types.MessageDelta
               { stop_reason = Some Agent_core.Types.EndTurn; usage = None });
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
  | Runtime_claude_code.Turn_failed detail
  | Runtime_claude_code.Turn_failed_with_observation { detail; _ } ->
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
  | Runtime_claude_code.Turn_failed _
  | Runtime_claude_code.Turn_failed_with_observation _
  | Runtime_claude_code.Quota_blocked _ ->
    Session_store.Provider_rejected
  | Runtime_claude_code.Context_window_exceeded
      { tool_effect_attempted; response_emitted; _ } ->
    (* Same activity axis as [context_overflow_retry_safe] above: an
       observation-free overflow exhausted the in-run shrink floor, any other
       was fenced without a retry. Both prove the bootstrap input itself is
       over capacity, so the recovery must not be auto-superseded next cycle
       (RFC claude-code-context-overflow-bounded-restart §6). *)
    Session_store.Input_rejected
      (if tool_effect_attempted || response_emitted
       then Session_store.Effect_fenced
       else Session_store.Bootstrap_floor_exceeded)
  | Runtime_claude_code.Stopped_by_host _ -> Session_store.Protocol_failed
;;

(* The CLI frame carries Anthropic exclusive counts; the shared constructor
   produces the canonical inclusive api_usage. One mapping for the result
   frame's total and for the sum a host stop carries. *)
let api_usage_of_turn_usage (usage : Runtime_claude_code.turn_usage) =
  Agent_core.Llm_provider.Backend_anthropic.usage_of_wire_counts
    ~input_tokens:usage.input_tokens
    ~output_tokens:usage.output_tokens
    ~cache_creation_input_tokens:usage.cache_creation_input_tokens
    ~cache_read_input_tokens:usage.cache_read_input_tokens
;;

module For_testing = struct
  let observe_stream_native_action ~turn_count ~observe event =
    match
      claude_stream_callback
        ~keeper_name:"test"
        ~raw_trace_run:None
        ~turn_count
        ~on_native_action:(Some observe)
        None
    with
    | Some callback -> callback event
    | None -> invalid_arg "native observer did not install Claude stream callback"
  ;;
  let bounded_probe_config = bounded_probe_config
  let host_stop_turn_identity = host_stop_turn_identity
  let recovery_failure_of_client_error = recovery_failure_of_client_error
end

(* RFC claude-code-context-overflow-bounded-restart §6.3: the same-run shrink
   retry is the one re-entry an input rejection admits. [on_shrink_retry]
   fires only after the sequence verified every authority condition — a typed
   observation-free overflow (the only shape mapped to [Api ContextOverflow]
   in [claude_error_to_core_error]), a strictly smaller next capacity, and the
   retry budget — so consuming the just-written [Input_rejected] recovery with
   an explicit [Restart_fresh] resolution cannot bypass the fence: a
   next-cycle replay never passes through that callback, and [Effect_fenced]
   recoveries are never resolved here because an effect-observed overflow is
   never retry-safe. A failed resolution is not retried here; the next
   attempt's claim surfaces the refusal instead. *)
let resolve_input_rejected_for_shrink_retry ~base_path ~keeper_name ~runtime_id ()
  =
  match Session_store.load ~base_path ~keeper_name with
  | Error _ -> ()
  | Ok
      ( Some
          ({ Session_store.phase = Recovery_required
                           { failure = Input_rejected Bootstrap_floor_exceeded
                           ; recovery_id
                           ; _
                           }
             ; runtime_id = stored_runtime_id
             ; _
             } as expected ) )
    when String.equal stored_runtime_id runtime_id ->
    (match
       Session_store.resolve_recovery
         ~base_path
         ~keeper_name
         ~expected
         ~recovery_id
         ~resolution:Session_store.Restart_fresh
         ~resolved_by:"context-overflow-shrink-retry"
         ~resolved_at:(Time_compat.now ())
     with
     | Ok _ -> ()
     | Error _ -> ())
  | Ok _ -> ()
;;

let run_without_lifecycle ~runtime_id ~keeper_name
    ~pre_tool_rejects ~base_path ~goal ~goal_blocks ~system_prompt
    ~tools ~initial_messages ~model_input_projection
    ~on_transmitted_model_input ~hooks ~context_injector
    ~context ~terminal_effect_state ~event_bus ~raw_trace ~on_event ~effect_disposition
    ~context_overflow_retry_safe
    ~on_official_client_result_handoff ~on_native_action
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
    let* native_posture =
      Host.resolve_native_posture
        ~base_path
        ~keeper_name
        ~client_label:"Claude Code"
        ~default:Runtime_native_tools.claude_code_default
        ~none_supported:true
    in
    (* The keeper TOML surface no longer declares setting sources — the
       fleet never used the field. The safe value the old admission rule
       degraded to is now the only value. *)
    let setting_sources = [] in
    (* Before the plan is read; see the same note in keeper_codex_runtime.ml. *)
    let tool_surface_sha256 =
      Session_store.tool_surface_sha256 ~native_posture tools
    in
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
    let* goal, images =
      match goal_blocks with
      | None -> Ok (goal, [])
      | Some blocks ->
        let* text, images =
          Host.text_and_images_of_blocks ~runtime_label ~field:"goal_blocks" blocks
        in
        Ok
          ( text
          , List.map
              (fun (image : Host.image_block) ->
                { Runtime_claude_code.media_type = image.Host.media_type
                ; base64_data = image.Host.base64_data
                })
              images )
    in
    (* Reported from [prepared.messages], the post-window list, and gated on
       the same [session_mode] the prompt below is built from -- one match,
       so the record cannot claim bytes the prompt did not carry. A [Start]
       renders the whole list; a [Resume] sends the goal alone and leaves the
       accumulated conversation in the session the CLI owns, which is the fact
       the composition line at the foot of this function already states. *)
    on_transmitted_model_input
      (match session_mode with
       | Runtime_claude_code.Start -> Host.Whole_input_transmitted prepared.messages
       | Runtime_claude_code.Resume _ -> Host.Held_by_client_session);
    let prompt =
      match session_mode with
      | Runtime_claude_code.Start -> initial_turn_prompt ~history ~goal
      | Runtime_claude_code.Resume _ -> goal
    in
    (* [None] means "masc named no system prompt, take the client's built-in
       one" since #33072 stopped passing [--system-prompt ""]. The probe and
       fusion callers build [None] directly and do not pass through this
       path. This composition always carries [prepared.system_prompt], which
       [Host.prepare_turn] refused when blank, so the joined text is never
       empty (#33165). *)
    let system_prompt =
      Some
        (prepared.system_prompt :: system_messages
         |> List.filter (fun text -> String.trim text <> "")
         |> String.concat "\n\n"
         |> String.trim)
    in
    let client_config : Runtime_claude_code.config =
      { cli_path = config.cli_path
      ; cwd = base_path
      ; model = config.model
      ; native = native_posture
      ; setting_sources
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
      ; wall_clock_ceiling_s =
          Runtime_inference.resolve_wall_clock_ceiling_s ~runtime_id
        (* A keeper turn is a conversation, not a schema contract: nothing
           downstream parses its text against a domain schema. *)
      ; output_schema = None
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
        ~on_result_handoff:on_official_client_result_handoff
        ()
    in
    let dynamic_tools = host_dynamic_tools in
    let* () =
      match
        Runtime_claude_code.validate_turn
          ~dynamic_tools
          ~session_mode
          client_config
          ~prompt
          ~images
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
    (* Snap the operator-declared effort so a value this lane cannot send does
       not fail the turn — the same posture as the Codex lane's catalog clamp,
       so which lane a keeper runs on no longer decides whether a config value
       is survivable. Two layers because they answer different owners: the
       catalog clamp obeys the model row (no-op today for anthropic rows,
       whose accepted set the capability layer withholds), and
       [cli_admitted_reasoning_effort] obeys the CLI's own vocabulary
       ([minimal] -> [low]). The same value feeds the raw_trace start record
       and the command line so observation matches the wire. *)
    let effective_reasoning_effort =
      Host.effective_reasoning_effort
        ~runtime_label
        ~keeper_name
        ~runtime_id
        ~model_id:config.model
        ~requested:prepared.reasoning_effort
      |> Option.map Runtime_claude_code.cli_admitted_reasoning_effort
    in
    (match prepared.reasoning_effort, effective_reasoning_effort with
     | Some asked, Some snapped
       when Llm_provider.Reasoning_effort.compare asked snapped <> 0 ->
       Log.Keeper.info
         ~keeper_name
         "%s reasoning effort snapped to the CLI vocabulary: model=%s asked=%s effective=%s"
         runtime_label
         (Option.value config.model ~default:runtime_id)
         (Llm_provider.Reasoning_effort.to_string asked)
         (Llm_provider.Reasoning_effort.to_string snapped)
     | _ -> ());
    let raw_trace_run =
      Host.start_raw_trace
        ~keeper_name
        ~raw_trace
        ~prompt
        ?model:config.model
        ?reasoning_effort:
          (Option.map
             Llm_provider.Reasoning_effort.to_string
             effective_reasoning_effort)
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
        ~on_result_handoff:on_official_client_result_handoff
        ()
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
    let settle_host_stop ~usage stop =
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
            ~model:(Option.value config.model ~default:runtime_id)
            ~session_id
            ~turn_id
            ~turns_used:turn_count
            ~latency_ms:
              (Some (Int.of_float ((Time_compat.now () -. started_at) *. 1000.0)))
            ~usage:(Option.map api_usage_of_turn_usage usage)
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
      let on_stream_event =
        claude_stream_callback ~keeper_name ~raw_trace_run ~turn_count ~on_native_action on_event
      in
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
             ?reasoning_effort:effective_reasoning_effort
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
             ~images
        in
        (match client_result with
         | Error (Runtime_claude_code.Stopped_by_host { stop; usage }) ->
           recovery_failure := Session_store.Host_hook_failed;
           (match !terminal_error with
            | Some detail -> Error (internal_error detail)
            | None -> settle_host_stop ~usage stop)
         | Error error ->
           context_overflow_retry_safe :=
             (match error with
              | Runtime_claude_code.Context_window_exceeded
                  { tool_effect_attempted = false; response_emitted = false; _ } ->
                true
              | _ -> false);
           (* A provider can reject after the child process spawned but
              before any response or MCP tool effect. Preserve the typed
              no-effect fact so failover is allowed for that narrow case. *)
           (match error with
            | Runtime_claude_code.Turn_failed_with_observation
                { tool_effect_attempted = false; response_emitted = false; _ }
            | Runtime_claude_code.Quota_blocked
                { tool_effect_attempted = false; response_emitted = false; _ } ->
              Atomic.set
                effect_disposition
                Keeper_provider_attempt_effect.No_effect_observed
            | _ -> ());
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
             ; usage = Option.map api_usage_of_turn_usage turn.usage
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
               ~usage_scope:
                 (if Option.is_some turn.usage
                  then Runtime_usage_scope.Per_request
                  else Runtime_usage_scope.Usage_scope_unavailable)
               ()
           in
           Ok
             { Runtime_agent.response
             ; checkpoint = None
             ; session_id = turn.session_id
             ; session_resumed = None
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
    ~tools ~initial_messages ~model_input_projection
    ~on_transmitted_model_input ~hooks ~context_injector
    ~context
    ?(terminal_effect_state = fun () -> Keeper_tools_agent_core.Terminal_effect_open)
    ?on_model_input_window_observation
    ?(on_official_client_result_handoff = fun ~invocation:_ ~content:_ -> ())
    ?on_native_action
    ~event_bus ~raw_trace ~on_event ~config () =
  let effect_disposition =
    Atomic.make Keeper_provider_attempt_effect.No_effect_observed
  in
  let observed_next_shrink_capacity_bytes = ref None in
  let observed_floor_capacity_bytes = ref None in
  let context_overflow_retry_safe = ref false in
  let starting_capacity_bytes =
    (* [max_capacity_bytes] is the runtime's declared ceiling: the shrink state
       reads it to discard a remembered capacity that now exceeds it. This lane
       passed [max_int], so a model that declares max-prompt-bytes was sent the
       whole history anyway and learned its ceiling only from the provider's
       rejection -- after the turn had already run. claude-sonnet-5 declares
       524288, and one live keeper spent 29 minutes per attempt discovering it
       (2026-08-24). A runtime that declares nothing keeps the old behaviour.

       The ceiling is the smaller of the model's max-prompt-bytes and the
       binding's max-request-body-bytes, which is what
       [declared_input_byte_ceiling_of_runtime_id] answers. keeper_unified_turn
       already sizes the pinned briefing from the same number and says the
       projection cuts the conversation window; this is that cut. *)
    Keeper_context_overflow_shrink_state.starting_capacity_bytes
      ~keeper_name
      ~runtime_id
      ~max_capacity_bytes:
        (Option.value
           (Runtime.declared_input_byte_ceiling_of_runtime_id runtime_id)
           ~default:unbounded_model_input_capacity_bytes)
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
        (* This runtime shrinks to the size the provider itself named
           ([observed_next_shrink_capacity_bytes]), not to a fraction of a
           declared request-body cap, and it charges no MASC-side reserve
           against that size. There is no local account that could rule the
           next size out, so the provider's own target stands. *)
        ~shrink_admits_history:(fun ~capacity_bytes:_ -> true)
        ~record_success:(fun ~capacity_bytes ->
          if capacity_bytes <> unbounded_model_input_capacity_bytes
          then
            Keeper_context_overflow_shrink_state.record_success
              ~keeper_name
              ~runtime_id
              ~capacity_bytes)
        ~on_shrink_retry:
          (fun ~shrink_attempt ~previous_capacity_bytes ~capacity_bytes ->
            resolve_input_rejected_for_shrink_retry
              ~base_path
              ~keeper_name
              ~runtime_id
              ();
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
                    ?on_model_input_window_observation
                    model_input_projection))
            (* Reported inside the attempt rather than from the projection.
               The projection cannot see [session_mode], and on this lane that
               is the whole question: it runs on every turn, but only a [Start]
               puts its result on the wire. A lane that reports nothing wrote
               every Claude Code turn's input attribution as zero
               (masc#32995); a lane that reports the projection on a resume
               attributes history the client already holds. *)
            ~on_transmitted_model_input
            ~hooks
          ~context_injector
          ~context
          ~terminal_effect_state
          ~event_bus
            ~raw_trace
            ~on_event
            ~effect_disposition
            ~context_overflow_retry_safe
        ~on_official_client_result_handoff ~on_native_action
            ~config)
        ())
  in
  { result; effect_disposition = Atomic.get effect_disposition }
;;
