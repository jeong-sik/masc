open Result.Syntax

let config_error = Keeper_official_client_host.config_error
let internal_error = Keeper_official_client_host.internal_error

module Host = Keeper_official_client_host

type successful_tool_completion =
  | No_successful_tool_completion
  | Successful_tool_completion

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; effect_disposition : Keeper_provider_attempt_effect.t
  ; successful_tool_completion : successful_tool_completion
  }

let runtime_label = "Codex"

let finish_raw_error ~keeper_name raw_trace_run error =
  match raw_trace_run with
  | None -> ()
  | Some active ->
    ignore
      (Host.observe_raw_trace ~keeper_name ~stage:Host.Run_finish (fun () ->
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
          (Host.observe_raw_trace
             ~keeper_name
             ~stage:Host.Assistant_block
             (fun () ->
                Agent_core.Raw_trace.record_assistant_block active ~block_index block))
      then all_blocks_recorded := false);
    let finished =
      Host.observe_raw_trace ~keeper_name ~stage:Host.Run_finish (fun () ->
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

(* Catalog-driven reasoning-effort clamping lives on the shared
   official-client host so Codex and Claude Code treat the same declared
   effort identically; see [Keeper_official_client_host.effective_reasoning_effort]. *)

let project_messages messages =
  let rec loop developer history = function
    | [] -> Ok (List.rev developer, List.rev history)
    | (message : Agent_core.Types.message) :: rest ->
      let text = Host.encode_history_message message in
      (match message.role with
       | Agent_core.Types.System -> loop (text :: developer) history rest
       | Agent_core.Types.User ->
         loop developer
           ({ Runtime_codex_app_server.role = User; text } :: history)
           rest
       | Agent_core.Types.Assistant ->
         loop developer
           ({ Runtime_codex_app_server.role = Assistant; text } :: history)
           rest
       | Agent_core.Types.Tool ->
         loop developer
           ({ Runtime_codex_app_server.role = User; text } :: history)
           rest)
  in
  loop [] [] messages
;;

let unbounded_model_input_capacity_bytes = max_int

let measure_model_input_message_bytes (message : Agent_core.Types.message) =
  String.length (Host.encode_history_message message)
;;

(* Keep the first official-client attempt byte-identical. Only the provider's
   exact typed overflow opens a bounded retry, and that retry windows the
   provider-bound copy without rewriting the durable conversation. *)
(* Same cut the Agent Core path makes, and the same reading it reports:
   [project_with_drop] keeps how much of the history survived, [project]
   throws it away. Discarding it wrote every official-client turn record with
   no window and no input composition, which is what [/context] reads. *)
let model_input_projection_for_capacity
    ~capacity_bytes
    ~observed_next_shrink_capacity_bytes
    ?on_model_input_window_observation
    source_projection
    messages =
  let history_atom_count = List.length messages in
  let windowed =
    if capacity_bytes = unbounded_model_input_capacity_bytes
    then (
      (* No cut is still a reading: everything offered was carried. *)
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
  (* Compute the next structural retry boundary from the current bounded
     history before source projections append synthetic evidence (for example
     Gate replay). Using the current window also means the oracle reaches
     [None] at the newest-atom floor instead of authorizing an identical
     provider retry from the original unwindowed history. *)
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
          ~measure_message_bytes:measure_model_input_message_bytes
          ~target_capacity_bytes
          windowed)
  in
  let* projected =
    match source_projection with
    | None -> Ok windowed
    | Some project -> project windowed
  in
  Ok projected
;;

let codex_dynamic_tool ~observe_effect_attempted ~observe_successful_tool_completion
    (tool : Host.dynamic_tool) :
    Runtime_codex_app_server.dynamic_tool =
  { tool with
    call =
      (fun ~call_id input ->
        (* Close the outer same-turn retry boundary before entering user/tool
           code. The handler may commit and then raise or be cancelled, so
           observing only its returned value would reopen a duplicate-effect
           window. *)
        observe_effect_attempted ();
        let result = tool.call ~call_id input in
        (* This is evidence that the handler returned a successful tool result,
           which is sufficient to accept a tool-only provider terminal. It is
           not durable-effect truth and grants no retry authority. *)
        if result.success then observe_successful_tool_completion ();
        result)
  }
;;

let codex_stream_callback ~keeper_name ~raw_trace_run ~turn_count ~on_native_action on_event =
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
        | Runtime_codex_app_server.Turn_started { turn_id; model } ->
          emit (Agent_core.Types.MessageStart { id = turn_id; model; usage = None })
        | Runtime_codex_app_server.Text_delta text ->
          Buffer.add_string streamed_text text;
          emit
            (Agent_core.Types.ContentBlockDelta
               { index = 0; delta = Agent_core.Types.TextDelta text })
        | Runtime_codex_app_server.Dynamic_tool_started
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
        | Runtime_codex_app_server.Dynamic_tool_finished { call_id } ->
          Option.iter
            (fun index ->
               Hashtbl.remove tool_indexes call_id;
               emit (Agent_core.Types.ContentBlockStop { index }))
            (Hashtbl.find_opt tool_indexes call_id)
        | Runtime_codex_app_server.Native_tool_started observation ->
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
        | Runtime_codex_app_server.Native_tool_finished observation ->
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
        | Runtime_codex_app_server.Turn_finished { text } ->
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

let codex_error_to_core_error = function
  | Runtime_codex_app_server.Invalid_config detail ->
    config_error ~field:"codex_app_server" detail
  | Runtime_codex_app_server.Subscription_required detail ->
    config_error ~field:"codex_subscription" detail
  | Runtime_codex_app_server.Context_window_exceeded
      { message; tool_effect_attempted = false } ->
    Agent_core.Error.Api
      (Llm_provider.Retry.ContextOverflow { message; limit = None })
  | Runtime_codex_app_server.Context_window_exceeded _ as error ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderReportedError
         { provider = "codex_app_server"
         ; error_type = Some "context_window_exceeded_after_tool_effect"
         ; detail = Runtime_codex_app_server.error_to_string error
         })
  (* Provider- and transport-side failures carry typed constructors so the
     lane rotation chain ([core_error_to_runtime_outcome] returns [None] for
     [Internal _], which short-circuits [lane_should_retry]) can judge them.
     Mirrors [claude_error_to_core_error] / [runtime_error_to_core_error]
     (antigravity); RFC-0370 §3.1. No catch-all: a new client error variant
     must decide its rotation class at compile time. *)
  | Runtime_codex_app_server.Spawn_failed detail
  | Runtime_codex_app_server.Process_exited detail ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderUnavailable
         { provider = "codex_app_server"; detail })
  | Runtime_codex_app_server.Protocol_error { stage; detail } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ParseError
         { detail = Printf.sprintf "%s: %s" stage detail })
  | Runtime_codex_app_server.Rpc_error { method_; code; message } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderReportedError
         { provider = "codex_app_server"
         ; error_type = Some "rpc_error"
         ; detail =
             Printf.sprintf
               "%s%s: %s"
               method_
               (Option.fold ~none:"" ~some:(Printf.sprintf " (code %d)") code)
               message
         })
  | Runtime_codex_app_server.Unsupported_server_request method_ ->
    Agent_core.Error.Provider
      (Llm_provider.Error.UnknownVariant
         { type_name = "codex_app_server.server_request"; value = method_ })
  (* Effectful failed turns are fenced out of same-turn retry by
     [Keeper_provider_attempt_effect] at the driver level, so this mapping
     stays purely descriptive of what the provider reported. *)
  | Runtime_codex_app_server.Turn_failed detail ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderReportedError
         { provider = "codex_app_server"
         ; error_type = Some "turn_failed"
         ; detail
         })
  | Runtime_codex_app_server.Timeout { seconds; turn_accepted = false } ->
    Agent_core.Error.Api
      (Agent_core.Retry.Timeout
         { message =
             Printf.sprintf
               "Codex app-server stream was idle for %.3fs before turn/start"
               seconds
         ; phase = None
         })
  (* Idle after [turn/start] was accepted is ambiguous: the upstream turn may
     still be executing and committing effects. Rotation would run the goal a
     second time, so this stays non-rotating; session recovery
     ([Transport_interrupted]) owns reconciliation. *)
  | Runtime_codex_app_server.Timeout { seconds; turn_accepted = true } ->
    Agent_core.Error.Internal
      (Printf.sprintf
         "Codex app-server stream was idle for %.3fs after turn/start was \
          accepted (not rotated: the upstream turn may still commit)"
         seconds)
  (* Server-reported "interrupted" turn status (deliberate host-side stop, for
     example shutdown): not a provider fault, so rotation to another runtime
     would re-run a turn that was intentionally stopped. Stays [Internal]. *)
  | Runtime_codex_app_server.Turn_interrupted ->
    Agent_core.Error.Internal
      (Runtime_codex_app_server.error_to_string Runtime_codex_app_server.Turn_interrupted)
  | Runtime_codex_app_server.Runtime_shutting_down ->
    Agent_core.Error.Internal
      (Runtime_codex_app_server.error_to_string
         Runtime_codex_app_server.Runtime_shutting_down)
  | Runtime_codex_app_server.Stopped_by_host _ ->
    Agent_core.Error.Internal
      "Codex host stop escaped the typed checkpoint boundary"
;;

let recovery_failure_of_client_error = function
  | Runtime_codex_app_server.Spawn_failed _ ->
    Keeper_official_client_session_store.Transient_spawn_failed
  | Runtime_codex_app_server.Turn_interrupted
  | Runtime_codex_app_server.Runtime_shutting_down
  | Runtime_codex_app_server.Process_exited _
  | Runtime_codex_app_server.Timeout _ ->
    Keeper_official_client_session_store.Transport_interrupted
  | Runtime_codex_app_server.Invalid_config _
  | Runtime_codex_app_server.Protocol_error _
  | Runtime_codex_app_server.Rpc_error _
  | Runtime_codex_app_server.Unsupported_server_request _ ->
    Keeper_official_client_session_store.Protocol_failed
  | Runtime_codex_app_server.Subscription_required _
  | Runtime_codex_app_server.Turn_failed _ ->
    Keeper_official_client_session_store.Provider_rejected
  | Runtime_codex_app_server.Context_window_exceeded
      { tool_effect_attempted; _ } ->
    (* Same admission rule as the Claude Code runtime: an input the provider
       proved over capacity must not be auto-replayed next cycle. The Codex
       error carries only the tool-effect axis, so an observed tool effect
       fences and everything else is a floor-exhausted rejection. *)
    Keeper_official_client_session_store.Input_rejected
      (if tool_effect_attempted
       then Keeper_official_client_session_store.Effect_fenced
       else Keeper_official_client_session_store.Bootstrap_floor_exceeded)
  | Runtime_codex_app_server.Stopped_by_host _ ->
    Keeper_official_client_session_store.Protocol_failed
;;

(* Codex ships its own file tools and neither it nor MASC can switch them
   off -- [permissions_profile_of_posture] says as much. Under [Native_read]
   they run in a read-only sandbox, so the model holds a working [Write] and a
   refused [apply_patch] at the same time and cannot tell them apart until one
   of them fails. The refusal it meets first is the one it reports: a keeper
   with an open write path stopped for six hours saying the workspace was
   read-only.

   This states which of the two the session refused. It is a projection of the
   configuration MASC already chose, not an instruction -- what the keeper does
   about it stays the keeper's.

   Checked against codex-cli 0.149.1 on 2026-08-25, profile ids re-read from
   0.153.2 on 2026-09-04. MASC reaches the read-only posture through the named
   permissions profile [:read-only] ([thread/start]'s [permissions]), not
   through [sandbox] and its [SandboxMode] vocabulary, which this client never
   sends. Such a session refuses a built-in patch with the wording this note
   contradicts: "patch rejected: writing is blocked by read-only sandbox"
   (openai/codex#30712, #24806).

   The MASC tools go on working because Codex does not apply the sandbox to
   MCP-provided tools. That is reported as a hole rather than a promise --
   openai/codex#4152, closed without an answer -- so it is the assumption to
   check first if writes start failing. If Codex closes it, [Native_read]
   leaves a keeper with no write path at all, and the posture is what has to
   change; a note about which tool to reach for would then be wrong. *)
let native_posture_note = function
  | Runtime_native_tools.Native_read ->
    [ "Your built-in file edits run under a read-only sandbox in this session, \
       so apply_patch and every other built-in write is refused. File changes \
       go through the Write and Edit tools, which are not sandboxed that way. \
       A refused built-in write does not mean the workspace is read-only."
    ]
  | Runtime_native_tools.Native_full | Runtime_native_tools.Native_none -> []
;;

let run_without_lifecycle ~runtime_id ~keeper_name
    ~pre_tool_rejects ~base_path ~goal ~goal_blocks
    ~system_prompt ~tools ~initial_messages ~model_input_projection
    ~on_transmitted_model_input ~hooks
    ~context_injector ~context ~terminal_effect_state ~event_bus ~raw_trace ~on_event
    ~observe_effect_attempted ~observe_successful_tool_completion
    ~on_official_client_result_handoff ~on_native_action
    ~(config : Runtime_execution.codex_app_server) =
  match Eio_context.get_env_opt (), Eio_context.get_clock_opt () with
  | None, _ ->
    Error
      (config_error
         ~field:"eio_env"
         "Codex app-server runtime requires the initialized Eio standard environment")
  | _, None ->
    Error
      (config_error
         ~field:"eio_clock"
         "Codex app-server runtime requires the initialized Eio clock")
  | Some env, Some clock ->
    let hooks = match hooks with Some hooks -> hooks | None -> Agent_core.Hooks.empty in
    let owner_epoch = Keeper_official_client_session_store.process_epoch () in
    let* stored_session =
      match Keeper_official_client_session_store.load ~base_path ~keeper_name with
      | Ok session -> Ok session
      | Error detail ->
        Error (internal_error ("Codex session binding load failed: " ^ detail))
    in
    let* stored_session =
      match stored_session with
      | Some
          ({ phase = (Start _ | Active _ | Turn_inflight _); _ } as expected) ->
        (match
           Keeper_official_client_session_store.reconcile_process_restart
             ~base_path
             ~keeper_name
             ~expected
             ~current_owner_epoch:owner_epoch
             ~required_at:(Time_compat.now ())
         with
         | Ok reconciled -> Ok (Some reconciled)
         | Error detail ->
           Error
             (config_error
                ~field:"official_client_session.phase"
                detail))
      | None | Some { phase = (Ready | Recovery_required _ | Settled _); _ } ->
        Ok stored_session
    in
    let* claim_plan =
      match
        Keeper_official_client_session_store.plan_claim
          ~expected:stored_session
          ~client_kind:Codex
          ~runtime_id
      with
      | Ok plan -> Ok plan
      | Error detail ->
        Error
          (config_error
             ~field:"official_client_session.claim"
             detail)
    in
    (* Before the plan is read. A moved surface has to change thread_mode and
       the ordinal too, not just what the store writes, or the adapter asks the
       provider to resume a thread the store has already replaced.
       [Host.prepare_turn] returns the same list it was given -- it only
       validates forced tool choice -- so hashing the input here is the digest
       that reaches [claim]. *)
    let* native_posture =
      Host.resolve_native_posture
        ~base_path
        ~keeper_name
        ~client_label:"Codex"
        ~default:Runtime_native_tools.codex_default
        ~none_supported:false
    in
    let tool_surface_sha256 =
      Keeper_official_client_session_store.tool_surface_sha256
        ~native_posture
        tools
    in
    let claim_plan =
      Keeper_official_client_session_store.reconcile_tool_surface
        claim_plan
        ~tool_surface_sha256
    in
    let thread_mode =
      match claim_plan.previous_settlement with
      | None -> Runtime_codex_app_server.Start
      | Some { session_id; _ } ->
        Runtime_codex_app_server.Resume { thread_id = session_id }
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
    (* Snap the operator-declared effort into the catalog's accepted set so a
       per-model cap (e.g. [Max] unsupported on a model that tops out at
       [XHigh]) does not fail the turn. The same value feeds the raw_trace
       start record and the request so observation matches the wire. *)
    let effective_reasoning_effort =
      Host.effective_reasoning_effort
        ~runtime_label
        ~keeper_name
        ~runtime_id
        ~model_id:config.model
        ~requested:prepared.reasoning_effort
    in
    let* developer_messages, history = project_messages prepared.messages in
    let* prompt, images =
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
                { Runtime_codex_app_server.media_type = image.Host.media_type
                ; base64_data = image.Host.base64_data
                })
              images )
    in
    (* [None] here means "send no developerInstructions": [optional_field]
       omits the member and the app-server runs the thread on Codex's own
       default instructions. The probe and fusion callers build [None] on
       purpose and do not pass through here. This composition always carries
       [prepared.system_prompt], which [Host.prepare_turn] refused when blank,
       so the joined text is never empty. A check on the joined text could
       not see a blank keeper prompt behind the posture note this lane
       appends (#33165). *)
    let developer_instructions =
      Some
        ((prepared.system_prompt :: native_posture_note native_posture)
         @ developer_messages
         |> List.filter (fun text -> String.trim text <> "")
         |> String.concat "\n\n"
         |> String.trim)
    in
    (* Reported from [prepared.messages], the post-window list, gated on the
       same [thread_mode] that decides whether [thread/inject_items] runs at
       all. Only a [Start] injects the history into the new thread; a [Resume]
       sends the prompt and leaves the conversation in the thread the
       app-server owns, so on that branch there is nothing here to attribute.
       The composition line further down states the same split. Reported once
       the composition is admitted: a turn refused above never dispatches, and
       a record saying it transmitted its whole input would be masc#32995's
       zero-bytes misreading with the sign flipped. *)
    on_transmitted_model_input
      (match thread_mode with
       | Runtime_codex_app_server.Start ->
         Host.Whole_input_transmitted prepared.messages
       | Runtime_codex_app_server.Resume _ -> Host.Held_by_client_session);
    let client_config =
      { Runtime_codex_app_server.cli_path = config.cli_path
      ; model = config.model
      ; native = native_posture
      ; developer_instructions
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
    let dynamic_tools =
      List.map
        (codex_dynamic_tool
           ~observe_effect_attempted
           ~observe_successful_tool_completion)
        host_dynamic_tools
    in
    (* The only size this tree reports for a turn is
       [keeper_unified_turn.ml]'s [system_and_user_bytes], which sums
       [system_prompt + world_state + user_message] and nothing else. The
       history and the tool declarations reach the provider through
       [thread/inject_items] and [thread/start]'s [dynamicTools], so a live
       keeper can report 6,971 bytes used of a 128,000 budget while the server
       answers that the context window is full (#28071). A [Start] also injects
       the whole history into the new thread, so "fresh" does not mean "empty
       context" — the mode is recorded because the injection only happens on
       that branch. Sizes are the bytes this process holds, not provider
       tokens; they bound the request, they do not price it. *)
    Log.Keeper.info
      ~keeper_name
      "%s turn composition: mode=%s prompt_bytes=%d developer_instructions_bytes=%d \
       history_messages=%d history_bytes=%d tools=%d tool_surface_bytes=%d"
      runtime_label
      (match thread_mode with
       | Runtime_codex_app_server.Start -> "start"
       | Runtime_codex_app_server.Resume _ -> "resume")
      (String.length prompt)
      (Option.fold ~none:0 ~some:String.length client_config.developer_instructions)
      (List.length history)
      (Runtime_codex_app_server.history_bytes history)
      (List.length dynamic_tools)
      (Runtime_codex_app_server.dynamic_tool_bytes dynamic_tools);
    let* () =
      match
        Runtime_codex_app_server.validate_turn
          ~dynamic_tools
          ~thread_mode
          ~cwd:Eio.Path.(Eio.Stdenv.fs env / base_path)
          client_config
          ~prompt
          ~images
      with
      | Ok () -> Ok ()
      | Error error -> Error (codex_error_to_core_error error)
    in
    let raw_trace_run =
      match raw_trace with
      | None -> None
      | Some sink ->
        Host.observe_raw_trace ~keeper_name ~stage:Host.Run_start (fun () ->
          Agent_core.Raw_trace.start_run
            sink
            ~agent_name:keeper_name
            ~prompt
            ?model:config.model
            ?reasoning_effort:
              (Option.map
                 Llm_provider.Reasoning_effort.to_string
                 effective_reasoning_effort)
            ())
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
    let dynamic_tools =
      List.map
        (codex_dynamic_tool
           ~observe_effect_attempted
           ~observe_successful_tool_completion)
        host_dynamic_tools
    in
    let* claimed_session =
      match
        Keeper_official_client_session_store.claim
          ~base_path
          ~keeper_name
          ~expected:stored_session
          ~client_kind:Codex
          ~owner_epoch
          ~runtime_id
          ~tool_surface_sha256
          ~updated_at:(Time_compat.now ())
      with
      | Ok session -> Ok session
      | Error detail ->
        let error = internal_error ("Codex session claim failed: " ^ detail) in
        finish_raw_error ~keeper_name raw_trace_run error;
        Error error
    in
    let session_state = ref claimed_session in
    let recovery_failure =
      ref Keeper_official_client_session_store.Transport_interrupted
    in
    let update_session label transition =
      match transition !session_state with
      | Ok next ->
        session_state := next;
        Ok ()
      | Error detail ->
        recovery_failure := Keeper_official_client_session_store.State_persistence_failed;
        Error (Printf.sprintf "Codex session %s failed: %s" label detail)
    in
    let require_recovery detail =
      match !session_state with
      | { Keeper_official_client_session_store.phase =
            (Ready | Settled _ | Recovery_required _)
        ; _
        } ->
        Ok ()
      | expected ->
        (match
           Keeper_official_client_session_store.require_recovery
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
      match
        Keeper_official_client_session_store.failure_disposition
          !recovery_failure
      with
      | Transient ->
        (match !session_state with
         | { phase = (Ready | Settled _ | Recovery_required _); _ } -> Ok ()
         | expected ->
           (match
              Keeper_official_client_session_store.release_transient
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
    let started_at = Time_compat.now () in
    let settle_host_stop stop =
      match (!session_state).Keeper_official_client_session_store.phase with
      | Turn_inflight { session_id; turn_id = Some turn_id; _ } ->
        let projected =
          Host.host_stop_result
            ~runtime_id
            ~model:(Option.value client_config.model ~default:runtime_id)
            ~session_id
            ~turn_id
            ~turns_used:turn_count
            ~latency_ms:
              (Some (Int.of_float ((Time_compat.now () -. started_at) *. 1000.0)))
              (* This adapter does not sum per-frame usage before a host
                 stop yet; the Codex app-server stream's counts are read only from
                 its terminal frame. *)
            ~usage:None
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
        recovery_failure := Keeper_official_client_session_store.State_persistence_failed;
        (match
           Keeper_official_client_session_store.settle
             ~base_path
             ~keeper_name
             ~expected:!session_state
             ~session_id
             ~turn_id
             ~updated_at:(Time_compat.now ())
         with
         | Error detail ->
           Error (internal_error ("Codex host-stop settlement failed: " ^ detail))
         | Ok settled ->
           session_state := settled;
           projected)
      | Ready | Start _ | Active _ | Turn_inflight { turn_id = None; _ }
      | Recovery_required _ | Settled _ ->
        Error
          (internal_error
             "Codex host stop arrived without an acknowledged provider turn")
    in
    let turn_result =
      try
        let on_stream_event =
          codex_stream_callback ~keeper_name ~raw_trace_run ~turn_count ~on_native_action on_event
        in
        (match
       Runtime_codex_app_server.run_turn
         ~mgr:(Eio.Stdenv.process_mgr env)
         ~clock
         ~cwd:Eio.Path.(Eio.Stdenv.fs env / base_path)
         ~dynamic_tools
         ?reasoning_effort:effective_reasoning_effort
         ~thread_mode
         ~history
         ?on_stream_event
         ~on_thread_ready:(fun ~thread_id ->
           update_session "active transition" (fun expected ->
             Keeper_official_client_session_store.mark_active
               ~base_path
               ~keeper_name
               ~expected
               ~session_id:thread_id
               ~updated_at:(Time_compat.now ())))
         ~on_turn_starting:(fun ~thread_id ->
           update_session "turn-starting transition" (fun expected ->
             Keeper_official_client_session_store.mark_turn_starting
               ~base_path
               ~keeper_name
               ~expected
               ~session_id:thread_id
               ~updated_at:(Time_compat.now ())))
         ~on_turn_started:(fun ~thread_id ~turn_id ->
           update_session "turn-started transition" (fun expected ->
             Keeper_official_client_session_store.mark_turn_started
               ~base_path
               ~keeper_name
               ~expected
               ~session_id:thread_id
               ~turn_id
               ~turn_count
               ~updated_at:(Time_compat.now ())))
         client_config
         ~prompt
         ~images
     with
     | Error (Runtime_codex_app_server.Stopped_by_host stop) ->
       recovery_failure := Keeper_official_client_session_store.Host_hook_failed;
       (match !terminal_error with
        | Some detail -> Error (internal_error detail)
        | None -> settle_host_stop stop)
     | Error error ->
       recovery_failure := recovery_failure_of_client_error error;
       Error (codex_error_to_core_error error)
     | Ok turn ->
       recovery_failure := Keeper_official_client_session_store.Protocol_failed;
       let expected_resumed =
         match thread_mode with
         | Runtime_codex_app_server.Start -> false
         | Runtime_codex_app_server.Resume _ -> true
       in
       let* () =
         if Bool.equal expected_resumed turn.resumed
         then Ok ()
         else
           Error
             (internal_error
                "Codex app-server reported a thread mode different from the requested session plan")
       in
       recovery_failure := Keeper_official_client_session_store.Host_hook_failed;
       let* () =
         match !terminal_error with
         | None -> Ok ()
         | Some detail -> Error (internal_error detail)
       in
       let latency_ms = Int.of_float ((Time_compat.now () -. started_at) *. 1000.0) in
       let response =
         { Agent_core.Types.id = turn.turn_id
         ; model = turn.model
         ; stop_reason = EndTurn
         ; content = [ Text turn.text ]
         ; usage = None
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
       recovery_failure := Keeper_official_client_session_store.State_persistence_failed;
       let* () =
         match
           Keeper_official_client_session_store.settle
             ~base_path
             ~keeper_name
             ~expected:!session_state
             ~session_id:turn.thread_id
             ~turn_id:turn.turn_id
             ~updated_at:(Time_compat.now ())
         with
         | Ok settled ->
           session_state := settled;
           Ok ()
         | Error detail ->
           Error (internal_error ("Codex session settlement failed: " ^ detail))
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
           ~attempt_details_source:"codex_app_server"
           ~agent_core_internal_runtime_allowed:false
           ~usage_scope:Runtime_usage_scope.Usage_scope_unavailable
           ()
       in
       Ok
         { Runtime_agent.response
         ; checkpoint = None
         ; session_id = turn.thread_id
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
                Keeper_official_client_session_store.Owner_stopped_turn
              | _ -> Keeper_official_client_session_store.Transport_interrupted);
        let detail = "Codex turn cancelled: " ^ Printexc.to_string exn in
        (match Eio.Cancel.protect (fun () -> settle_failed_claim detail) with
         | Ok () -> ()
         | Error recovery_detail ->
           Log.Keeper.error
             ~keeper_name
             "Codex cancellation recovery persistence failed: %s"
             recovery_detail);
        (match
           Eio.Cancel.protect (fun () ->
             finish_raw_error ~keeper_name raw_trace_run (internal_error detail))
         with
         | () -> ());
        Printexc.raise_with_backtrace exn backtrace
    in
    let turn_result =
      match turn_result with
      | Ok result -> Ok (finish_raw_success ~keeper_name raw_trace_run result)
      | Error error ->
        finish_raw_error ~keeper_name raw_trace_run error;
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
                  "Codex turn failed and recovery state persistence also failed: original=%s recovery=%s"
               original_detail
               recovery_detail))))
;;


(* RFC claude-code-context-overflow-bounded-restart §6.3, same rule as the
   Claude Code runtime: the same-run shrink retry is the one re-entry an
   input rejection admits. [on_shrink_retry] fires only after the sequence
   verified the typed observation-free overflow and the strictly smaller
   next capacity, so consuming the just-written
   [Input_rejected] recovery with an explicit [Restart_fresh] resolution
   cannot bypass the fence. A failed resolution is not retried here; the next
   attempt's claim surfaces the refusal instead. *)
let resolve_input_rejected_for_shrink_retry ~base_path ~keeper_name ~runtime_id
  ()
  =
  match Keeper_official_client_session_store.load ~base_path ~keeper_name with
  | Error _ -> ()
  | Ok
      ( Some
          ( { Keeper_official_client_session_store.phase = Recovery_required
                            { failure = Input_rejected Bootstrap_floor_exceeded
                            ; recovery_id
                            ; _
                            }
            ; runtime_id = stored_runtime_id
            ; _
            } as expected ) )
    when String.equal stored_runtime_id runtime_id ->
    (match
       Keeper_official_client_session_store.resolve_recovery
         ~base_path
         ~keeper_name
         ~expected
         ~recovery_id
         ~resolution:Keeper_official_client_session_store.Restart_fresh
         ~resolved_by:"context-overflow-shrink-retry"
         ~resolved_at:(Time_compat.now ())
     with
     | Ok _ -> ()
     | Error _ -> ())
  | Ok _ -> ()
;;
let run ~runtime_id ~keeper_name ~pre_tool_rejects ~base_path ~goal ~goal_blocks
    ~system_prompt ~tools ~initial_messages ~model_input_projection
    ~on_transmitted_model_input ~hooks
    ~context_injector ~context
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
  let successful_tool_completion = Atomic.make No_successful_tool_completion in
  let observe_successful_tool_completion () =
    Atomic.set successful_tool_completion Successful_tool_completion
  in
  let observed_next_shrink_capacity_bytes = ref None in
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
        Keeper_provider_attempt_effect.allows_same_turn_retry
          (Atomic.get effect_disposition)
        && Option.is_some !observed_next_shrink_capacity_bytes)
      ~shrink_capacity:(fun ~capacity_bytes:_ ~default_capacity_bytes ->
        Option.value
          !observed_next_shrink_capacity_bytes
          ~default:(max 1 default_capacity_bytes))
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
            "Codex typed context overflow; shrinking provider-bound history: attempt=%d previous_capacity_bytes=%d capacity_bytes=%d"
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
                  ?on_model_input_window_observation
                  model_input_projection))
          (* Reported inside the attempt rather than from the projection. The
             projection cannot see [thread_mode], and that is what decides
             whether its result is injected into the thread or dropped. A lane
             that reports nothing wrote every Codex turn's input attribution
             as zero (masc#32995); a lane that reports the projection on a
             resume attributes history the thread already holds. *)
          ~on_transmitted_model_input
          ~hooks
          ~context_injector
          ~context
          ~terminal_effect_state
        ~on_official_client_result_handoff ~on_native_action
          ~event_bus
          ~raw_trace
          ~on_event
          ~observe_effect_attempted
          ~observe_successful_tool_completion
          ~config)
      ())
  in
  { result
  ; effect_disposition = Atomic.get effect_disposition
  ; successful_tool_completion = Atomic.get successful_tool_completion
  }
;;

module For_testing = struct
  let observe_stream_native_action ~turn_count ~observe event =
    match
      codex_stream_callback
        ~keeper_name:"test"
        ~raw_trace_run:None
        ~turn_count
        ~on_native_action:(Some observe)
        None
    with
    | Some callback -> callback event
    | None -> invalid_arg "native observer did not install Codex stream callback"
  ;;
  let native_posture_note = native_posture_note
  let codex_error_to_core_error = codex_error_to_core_error
  let recovery_failure_of_client_error = recovery_failure_of_client_error
end
