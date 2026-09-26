open Result.Syntax

module Host = Keeper_official_client_host
module Session_store = Keeper_official_client_session_store

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; settled_session : Keeper_official_client_session_store.t option
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

(* A keeper turn cannot start without its labels; the missing asset is a
   packaging fault, raised where the turn is framed. *)
let required_label = function
  | Ok label -> label
  | Error message -> invalid_arg message

let system_instructions_label () =
  required_label (Antigravity_input_frame.system_instructions_label ())

let current_goal_label () = required_label (Antigravity_input_frame.current_goal_label ())
let prompt_section_separator = Antigravity_input_frame.section_separator

let measure_model_input_message_bytes (message : Agent_core.Types.message) =
  String.length (Host.history_role_label message.role)
  + String.length (Host.encode_history_message message)
  + String.length prompt_section_separator
;;

let prompt_section_framing_reserved_bytes () =
  String.length (system_instructions_label ())
  + String.length (current_goal_label ())
  + (2 * String.length prompt_section_separator)
;;

(* The carried front is a position in durable checkpoint history, so admit it
   before the source projection appends its bounded Gate replay reference.
   The byte window still runs last and therefore charges every message that
   can reach the CLI. Its observation is mapped back to the durable history:
   a source-only atom is transmitted context, but cannot become a front that
   a later checkpoint history is expected to open. *)
let bounded_history_projection ~capacity_bytes ~reserved_bytes
    ?on_model_input_window_observation ?carried_front_seed ?librarian_front ?on_carried_front
    ~turn_start ~keeper_name ~runtime_id source_projection
  : Agent_core.Agent.model_input_projection
  =
  fun history_messages ->
  let* librarian_front = Host.read_librarian_front librarian_front history_messages in
  let carried_front_seed = Host.read_seed_once carried_front_seed in
  (* The window drops atoms, never a pinned message, so a request whose
     pinned messages -- the hooks' system context and the preamble -- exceed
     what the fixed sections leave is refused for every front. A working
     state is pinned too, and whether it goes is decided before anything is
     sent ([Host.compose_librarian_range], RFC-0460): it is carried only
     where it displaces none of the range's atoms, and otherwise the
     Librarian position goes alone. The empty history stays open to every
     composition, because that decision is what keeps a working state from
     going out with no turn to answer; a range with none is the ceiling
     saying it cannot hold one atom of this conversation, and the goal and
     system prompt still go out, as the Claude Code lane's shrink floor
     composes on purpose. *)
  let compose librarian_front =
    let carried =
      Host.carried_start_range
        ~keeper_name
        ~runtime_id
        ~carried_front_seed
        ~librarian_front
        ~own_first_atom:0
        ~turn_start
        history_messages
    in
    Host.window_carried_range
      ~measure_message_bytes:measure_model_input_message_bytes
      ~capacity_bytes
      ~reserved_bytes
      ?source_projection
      carried
  in
  let* windowed =
    Host.compose_librarian_range ~keeper_name ~runtime_id ~compose librarian_front
  in
  Option.iter
    (fun observe ->
       observe
         windowed.Host.carried.Host.front
         ~transmitted_bytes:windowed.Host.carried.Host.transmitted_bytes)
    on_carried_front;
  Option.iter
    (fun observe ->
       Option.iter
         observe
         (Runtime_model_input_tail_window.observe
            ~digest_at:(Runtime_model_input_tail_window.atom_opening_digest history_messages)
            ~history_atom_count:windowed.Host.carried.Host.history_atom_count
            (Host.windowed_projection windowed)))
    on_model_input_window_observation;
  Ok windowed.Host.sent
;;

let capacity_bounded_model_input_projection ~declared_max_prompt_bytes
    ~system_prompt ~goal ?on_model_input_window_observation ?carried_front_seed
    ?librarian_front ?on_carried_front ~turn_start ~keeper_name ~runtime_id source_projection
  =
  match declared_max_prompt_bytes with
  | None ->
    Error
      (config_error
         ~field:"max_prompt_bytes"
         "Antigravity requires max-prompt-bytes because the CLI has no typed oversized-input refusal")
  | Some capacity_bytes ->
    let reserved_bytes =
      String.length system_prompt
      + String.length goal
      + prompt_section_framing_reserved_bytes ()
    in
    if reserved_bytes >= capacity_bytes
    then
      Error
        (config_error
           ~field:"max_prompt_bytes"
           (Printf.sprintf
              "Antigravity fixed prompt sections measure %d bytes, at or above max-prompt-bytes %d"
              reserved_bytes
              capacity_bytes))
    else
      Ok
        (Some
           (bounded_history_projection
              ~capacity_bytes
              ~reserved_bytes
              ?on_model_input_window_observation
              ?carried_front_seed
              ?librarian_front
              ?on_carried_front
              ~turn_start
              ~keeper_name
              ~runtime_id
              source_projection))
;;

let prompt_for_turn ~is_resume ~goal (prepared : Host.prepared_turn) =
  if is_resume
  then
    (* The provider conversation already owns the static system prompt and
       seeded history. The hook context is turn-local, though, so dropping its
       typed carrier on resume changes provider meaning. Nothing is recorded
       as held on this lane, so every carried context is sent. *)
    Ok (Host.resume_prompt ~goal ~held:[] prepared.messages).Host.prompt
  else
    let* history = render_messages prepared.messages in
    Ok
      ([ String_util.trim_nonempty prepared.system_prompt
         |> Option.map (fun value -> system_instructions_label () ^ value)
      ; String_util.trim_nonempty history
      ; Some (current_goal_label () ^ goal)
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
  ; content_blocks = result.content_blocks
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

(* The CLI reports an exclusive prompt count: [parse_usage] accepts a frame
   only when total_tokens = input_tokens + output_tokens, so the cache it
   read is not in either. [api_usage.input_tokens] is the inclusive total, so
   the components go through the shared constructor -- assembling the record
   by hand put an exclusive count in an inclusive slot, and every cache hit
   went missing from context occupancy. The keeper's claude_code sibling
   builds through it too. *)
let api_usage_of_antigravity_usage (usage : Runtime_antigravity.usage) =
  Agent_core.Llm_provider.Backend_anthropic.usage_of_wire_counts
    ~input_tokens:usage.input_tokens
    ~output_tokens:usage.output_tokens
    ~cache_creation_input_tokens:0
    ~cache_read_input_tokens:usage.cache_read_tokens
;;

(* The CLI's stdout and MASC's MCP server are two channels into one stream.
   agy prints init before it calls a tool, but MessageStart is emitted only
   after [on_conversation_ready] has written the session, and a tool call
   the MCP server answers during that write would open its blocks before
   the message. *)
type mcp_blocks =
  | Held of Agent_core.Types.sse_event list
      (** Blocks of tool calls answered before MessageStart, newest first. A
          turn that fails before init opens no message, and they are not
          streamed. *)
  | Streaming

let stream_projection ~keeper_name ~raw_trace_run ~turn_count ~on_native_action ~on_usage_report
    ~position on_event =
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
    let mcp_blocks = ref (Held []) in
    let emit_mcp_block event =
      match !mcp_blocks with
      | Streaming -> emit event
      | Held held -> mcp_blocks := Held (event :: held)
    in
    (* Emitting can yield to the MCP server's fiber, which then holds more
       blocks; they go out in the next pass, and streaming starts only when
       a pass finds nothing held. *)
    let rec release_mcp_blocks () =
      match !mcp_blocks with
      | Streaming | Held [] -> mcp_blocks := Streaming
      | Held held ->
        mcp_blocks := Held [];
        List.iter emit (List.rev held);
        release_mcp_blocks ()
    in
    (* Each response step is one assistant message; agy names it by its
       [step_index]. *)
    let text_stream = Keeper_official_client_text_stream.create ~equal:Int.equal () in
    { on_runtime_event =
        (function
          | Runtime_antigravity.Turn_started { conversation_id; model } ->
            emit
              (Agent_core.Types.MessageStart
                 { id = provider_turn_identity ~conversation_id ~num_turns:turn_count
                 ; model
                 ; usage = None
                 });
            release_mcp_blocks ()
          | Runtime_antigravity.Text_delta { step_index; text } ->
            emit
              (Agent_core.Types.ContentBlockDelta
                 { index = 0
                 ; delta =
                     Agent_core.Types.TextDelta
                       (Keeper_official_client_text_stream.forward
                          text_stream
                          ~message:step_index
                          text)
                 })
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
          | Runtime_antigravity.Usage_reported { conversation_id; model; num_turns; usage } ->
            (* Keyed as the completion hook keys an Antigravity turn: the
               CLI's own turn count and the identity built from it. *)
            Option.iter
              (fun report ->
                 report
                   { Keeper_client_usage_report.official_turn = num_turns
                   ; response_id = provider_turn_identity ~conversation_id ~num_turns
                   ; model
                   ; conversation_id
                   ; position
                   ; usage_scope = Runtime_usage_scope.Conversation_cumulative
                   ; count =
                       Keeper_client_usage_report.Running_count
                         (api_usage_of_antigravity_usage usage)
                   ; vendor_total_tokens = Some usage.total_tokens
                   })
              on_usage_report
          | Runtime_antigravity.Turn_finished { text = _ } ->
            emit
              (Agent_core.Types.MessageDelta
                 { stop_reason = Some Agent_core.Types.EndTurn; usage = None });
            emit Agent_core.Types.MessageStop)
    ; on_tool_started =
        (fun ~call_id ~tool_name ~arguments ->
          Keeper_official_client_text_stream.tool_row text_stream;
          let index = !next_tool_index in
          incr next_tool_index;
          Hashtbl.replace tool_indexes call_id index;
          emit_mcp_block
            (Agent_core.Types.ContentBlockStart
               { index
               ; content_type = "tool_use"
               ; tool_id = Some call_id
               ; tool_name = Some tool_name
               });
          emit_mcp_block
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
               emit_mcp_block (Agent_core.Types.ContentBlockStop { index }))
            (Hashtbl.find_opt tool_indexes call_id))
    }
;;

let run_without_lifecycle ~official_task_reference ~accepts_image_input ~on_session_settled ~required_native_posture ~official_client_continuation ~runtime_id ~keeper_name
    ~on_model_input_window_observation
    ~carried_front_seed
    ~librarian_front
    ~on_carried_front
    ~turn_start
    ~pre_tool_rejects ~base_path ~goal ~goal_blocks
    ~system_prompt ~tools ~initial_messages ~model_input_projection
    ~on_transmitted_model_input ~hooks
    ~context_injector ~context ~terminal_effect_state ~event_bus ~raw_trace ~on_event
    ~observe_effect_attempted
    ~on_official_client_tool_boundary ~on_official_client_result_handoff ~on_native_action
    ~on_usage_report ~(config : Runtime_execution.antigravity_cli) =
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
      |> Result.map_error Session_store.core_error_of_claim_error
    in
    (* Before the plan is read; see the note in keeper_codex_runtime.ml. A
       moved surface has to change conversation_mode and the ordinal too, not
       just what the store writes. *)
    let* native_posture =
      Host.resolve_native_posture
        ~posture_source:
          (Runtime_native_tools.posture_source_of_required required_native_posture)
        ~base_path
        ~keeper_name
        ~client_label:"Antigravity"
        ~default:Runtime_native_tools.antigravity_default
        ~none_supported:(Runtime_execution.supports_native_none (Antigravity_cli config))
    in
    let runtime_root = Common.masc_dir_from_base_path ~base_path in
    let owner_leaf = Runtime_antigravity_home.keeper_owner_leaf
        ~keeper_name ~oauth_source:config.oauth_source in
    let account_home = Runtime_antigravity_home.home_path ~runtime_root ~owner_leaf in
    let* sandbox_profile = match required_native_posture with
      | Some _ -> Ok None
      | None ->
        let* defaults =
          Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
            ~base_path keeper_name
          |> Result.map_error (fun error -> config_error ~field:"keeper.sandbox_profile"
            (Keeper_types_profile.keeper_toml_load_error_to_string error)) in
        (match defaults.sandbox_profile with
         | Some profile -> Ok (Some profile)
         | None -> Error (config_error ~field:"keeper.sandbox_profile"
             "Antigravity requires an explicit Keeper sandbox profile")) in
    let* add_dirs =
      let rec canonicalize = function
        | [] -> Ok []
        | path :: rest ->
          let* actual = Runtime_antigravity_home.canonical_workspace path
            |> Result.map_error home_error_to_core_error in
          let* rest = canonicalize rest in Ok (actual :: rest) in
      canonicalize config.add_dirs in
    let native_workspace, native_workspace_note =
      match sandbox_profile with
      | Some profile when Keeper_types_profile_sandbox.tree_location_of_profile profile
          = Keeper_types_profile_sandbox.Shared_mount ->
        let path = Filename.concat base_path
            (Keeper_sandbox.host_root_rel_of_profile profile keeper_name) in
        Runtime_antigravity_home.Shared_workspace path,
        Printf.sprintf
          "Antigravity native tools use the host workspace %s, the same files mounted at %s for MASC tools. Native commands run in the official client's host sandbox, not inside the Keeper container."
          path (Keeper_sandbox.container_root keeper_name)
      | None | Some _ ->
        Runtime_antigravity_home.Private_workspace,
        "Antigravity native tools use a separate private host workspace. They cannot access the Keeper's endpoint-owned working tree. Use MASC tools for that tree; native commands run in the official client's host sandbox." in
    let* () = if String.trim system_prompt = ""
      then Error (config_error ~field:"system_prompt" "system prompt must not be blank")
      else Ok () in
    let native_workspace_note = native_workspace_note ^
      " Explicit operator-granted additional native directories: " ^
      Yojson.Safe.to_string (`List (List.map (fun path -> `String path) add_dirs)) in
    let system_prompt = system_prompt ^ "\n\n" ^ native_workspace_note in
    let tool_surface_sha256 =
      Session_store.tool_surface_sha256 ~account_home ~native_posture tools
    in
    let* () = match official_client_continuation with
      | None -> Ok ()
      | Some checkpoint ->
        Keeper_official_client_session_store.validate_continuation ~checkpoint
          ~expected:stored_session ~client_kind:Antigravity ~runtime_id ~tool_surface_sha256
        |> Result.map_error (config_error ~field:"official_client_session.gate_continuation") in
    let claim_plan =
      Session_store.reconcile_tool_surface claim_plan ~tool_surface_sha256
    in
    (* This CLI offers no replaceable configuration channel. A vendor session
       that settled against another canonical history or system prompt is
       superseded by a fresh one seeded from the canonical source; ephemeral
       world context remains on the existing per-turn prompt path. *)
    let snapshot = `Assoc ["system_prompt", `String system_prompt;
      "messages", `List (List.map Keeper_official_client_context_codec.to_json initial_messages)] in
    let snapshot_sha256 = snapshot |> Yojson.Safe.to_string
      |> Digestif.SHA256.digest_string |> Digestif.SHA256.to_hex in
    let admission_error reason = config_error
        ~field:"official_client_session.context_admission"
        (Session_store.context_admission_error_to_string reason) in
    (* A Gate continuation is bound to its original vendor session: completion
       requires that session to settle again, so a fresh one would run the
       effects and then fail. It keeps the refusal, before any dispatch. *)
    let* reconciled_plan = match official_client_continuation with
      | Some _ when Option.is_some claim_plan.previous_settlement ->
        Session_store.validate_unchanged_context ~expected:stored_session ~snapshot_sha256
        |> Result.map (fun () -> claim_plan)
        |> Result.map_error admission_error
      | Some _ | None ->
        Ok (Session_store.reconcile_context claim_plan ~expected:stored_session ~snapshot_sha256) in
    (match claim_plan.previous_settlement, reconciled_plan.previous_settlement with
     | Some { session_id; _ }, None ->
       Log.Keeper.info
         "antigravity: keeper=%s vendor session %s did not settle against the current canonical history and system prompt; starting a fresh session"
         keeper_name session_id
     | Some _, Some _ | None, (Some _ | None) -> ());
    let claim_plan = reconciled_plan in
    let conversation_mode =
      match claim_plan.previous_settlement with
      | None -> Runtime_antigravity.Start
      | Some { session_id; _ } ->
        Runtime_antigravity.Resume { conversation_id = session_id }
    in
    let is_resume = Option.is_some claim_plan.previous_settlement in
    let context_frontier : Session_store.context_frontier =
      {snapshot_sha256; message_count=List.length initial_messages;
       delivery=Canonical_source_guard; acknowledged_turn=None; held_context=[]} in
    let turn_count = claim_plan.turn_count in
    let* goal =
      match goal_blocks with
      | None -> Ok goal
      | Some blocks -> Host.text_of_blocks ~runtime_label ~field:"goal_blocks" blocks
    in
    let declared_max_prompt_bytes =
      Runtime_inference.resolve_max_prompt_bytes ~runtime_id
    in
    let* capacity_bytes =
      match declared_max_prompt_bytes with
      | Some capacity_bytes -> Ok capacity_bytes
      | None ->
        Error
          (config_error
             ~field:"max_prompt_bytes"
             "Antigravity requires max-prompt-bytes because the CLI has no typed oversized-input refusal")
    in
    let* () = match official_task_reference with
      | None -> Ok ()
      | Some _ -> Error (config_error ~field:"official_client_session.context_admission"
          "historical_task_reference_unavailable: this client cannot replace task-reference context without replaying it as user input") in
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
        ~model_input_projection:(if is_resume then model_input_projection else None)
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
    let* prepared =
      if is_resume
      then Ok prepared
      else
        let* capacity_projection =
          capacity_bounded_model_input_projection
            ~declared_max_prompt_bytes
            ~system_prompt:prepared.system_prompt
            ~goal
            ?on_model_input_window_observation
            ?carried_front_seed
            ?librarian_front
            ?on_carried_front
            ~turn_start
            ~keeper_name
            ~runtime_id
            model_input_projection
        in
        let* messages =
          match capacity_projection with
          | None -> Ok prepared.messages
          | Some project ->
            (try project prepared.messages with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn ->
               Error
                 (Host.internal_error
                    (runtime_label
                     ^ " runtime model input projection raised: "
                     ^ Printexc.to_string exn)))
        in
        Ok { prepared with messages }
    in
    (* [prompt_for_turn] renders [prepared.system_prompt] as the
       system-instructions section; [Host.prepare_turn] has already refused a
       blank one, so the section is always present on a start (#33165). *)
    (* This is the prepared attribution, not transmission evidence. The
       runtime emits it only after writing the complete prompt to the CLI. *)
    let report_transmitted_input () =
      on_transmitted_model_input
        (if is_resume
         then Host.Held_by_client_session
         else Host.Whole_input_transmitted prepared.messages)
    in
    let* prompt = prompt_for_turn ~is_resume ~goal prepared in
    let* () =
      if String.length prompt <= capacity_bytes
      then Ok ()
      else
        Error
          (config_error
             ~field:"max_prompt_bytes"
             (Printf.sprintf
                "Antigravity final prompt measures %d bytes, above max-prompt-bytes %d"
                (String.length prompt)
                capacity_bytes))
    in
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
      (string_of_int capacity_bytes);
    let terminal_error = ref None in
    let* dynamic_tools =
      Host.dynamic_tools
        ~content_transport:Runtime_official_client_tool.Mcp
        ~accepts_image_input
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
        ?on_tool_boundary:on_official_client_tool_boundary
        ~on_result_handoff:on_official_client_result_handoff
        ()
    in
    let* home =
      Runtime_antigravity_home.prepare
        ~runtime_root
        ~owner_leaf
        ~oauth_source:config.oauth_source
      |> Result.map_error home_error_to_core_error
    in
    let* () =
      match native_workspace, sandbox_profile with
      | Runtime_antigravity_home.Shared_workspace _, Some profile ->
        (try
           ignore (Keeper_alerting_path.ensure_sandbox_bundle_for_profile
             ~config:(Workspace.default_config base_path) ~name:keeper_name
             ~sandbox_profile:profile : string list);
           Ok ()
         with
         | Sys_error detail -> Error (config_error ~field:"native_workspace" detail)
         | Unix.Unix_error (error, _, _) ->
           Error (config_error ~field:"native_workspace" (Unix.error_message error)))
      | _ -> Ok () in
    let* native_cwd = Runtime_antigravity_home.prepare_native_tools home
        ~posture:native_posture ~workspace:native_workspace ~additional_workspaces:add_dirs
      |> Result.map_error home_error_to_core_error in
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
      ; cwd = native_cwd
      ; add_dirs
      ; model = config.model
      ; agent = config.agent
      ; effort = config.effort
      ; (* Permission rules enforce read/full. Plan is an instruction mode;
           Accept_edits suppresses diff review only for admitted Yolo turns.
           The official client's host sandbox remains enabled in both. *)
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
      (* A keeper turn is a conversation, not a schema contract: nothing
         downstream parses its text against a domain schema. *)
      ; output_schema = None
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
        ~content_transport:Runtime_official_client_tool.Mcp
        ~accepts_image_input
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
        ?on_tool_boundary:on_official_client_tool_boundary
        ~on_result_handoff:on_official_client_result_handoff
        ()
    in
    let dynamic_tools =
      List.map (antigravity_dynamic_tool ~observe_effect_attempted) dynamic_tools
    in
    let* claimed_session =
      match
        Session_store.claim_with_context_frontier
          ~context_frontier:(Some context_frontier)
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
    let process_mgr = (Posix_spawn_process_mgr.foreground_mgr ~clock
      ~grace_seconds:Process_eio.child_exit_grace_seconds) in
    let process_cwd = Eio.Path.(Eio.Stdenv.fs env / native_cwd) in
    let started_at = Time_compat.now () in
      let stream =
        stream_projection ~keeper_name ~raw_trace_run ~turn_count ~on_native_action
          ~on_usage_report
          ~position:
            (match conversation_mode with
             | Runtime_antigravity.Start -> Keeper_usage_resolution.Fresh
             | Runtime_antigravity.Resume _ -> Keeper_usage_resolution.Resumed)
          on_event
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
              (* The antigravity stream's counts are read only from its
                 terminal frame, which a host stop precedes, so no request's
                 occupancy is known here. *)
            ~request_context:None
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
           on_session_settled settled;
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
              (Runtime_official_client_mcp_http.mcp_config_json
                 bridge
                 ~eager_tools:
                   (List.map (fun (tool : Host.dynamic_tool) -> tool.name) dynamic_tools))
            |> Result.map_error (fun error ->
              recovery_failure := Session_store.State_persistence_failed;
              home_error_to_core_error error)
          in
          (* A turn the runtime completed as the abort arrived is a
             completed turn: its answer stands and the abort is moot. *)
          match
            Watched_work.run
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
                      ~on_prompt_sent:report_transmitted_input
                      ~on_stream_event:stream.on_runtime_event
                      client_config
                      ~prompt))
              ~watcher:(fun () -> `Abort (Eio.Promise.await abort_turn))
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
    let settle_cancellation exn =
      let backtrace = Printexc.get_raw_backtrace () in
      recovery_failure
        := (if Keeper_owner_signals.is_owner_cancel_reason exn then
              Session_store.Owner_stopped_turn
            else Session_store.Transport_interrupted);
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
      try
        match run_client () with
        | Error error -> Error error
        | Ok (`Stopped stop) ->
          recovery_failure := Session_store.Host_hook_failed;
          (match stop, !terminal_error with
           | Host.Terminal_tool_boundary _, _
          when Option.is_some on_official_client_tool_boundary -> settle_host_stop stop
           | _, Some detail -> Error (internal_error detail)
           | _, None -> settle_host_stop stop)
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
          let usage = api_usage_of_antigravity_usage turn.usage in
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
            |> Result.map (fun settled -> session_state := settled; on_session_settled settled)
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
            ; session_resumed = Some turn.resumed
            ; turns = turn.num_turns
            ; trace_ref = None
            ; run_validation = None
            ; runtime_observation = Some runtime_observation
            ; cooperative_boundary = None
            ; stop_reason = Completed
            }
      with
      (* A stop the owner raised is not an ambiguity: it knows the turn did
         not finish and why. Only an unexplained cancellation needs an
         operator to adjudicate what the transport left behind (#28012). *)
      | Eio.Cancel.Cancelled _ as exn -> settle_cancellation exn
      | exn when Keeper_owner_signals.is_owner_cancel_reason exn ->
        settle_cancellation exn
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

let run ?official_task_reference ~accepts_image_input ?required_native_posture ?official_client_continuation ~runtime_id ~keeper_name ~pre_tool_rejects ~base_path ~goal ~goal_blocks ~system_prompt
    ~tools ~initial_messages ~model_input_projection
    ~on_transmitted_model_input ~hooks ~context_injector
    ~context
    ?(terminal_effect_state = fun () -> Keeper_tools_agent_core.Terminal_effect_open)
    ?on_model_input_window_observation
    ?carried_front_seed
    ?librarian_front
    ?on_carried_front
    ~turn_start
    ?on_official_client_tool_boundary
    ?(on_official_client_result_handoff = fun ~invocation:_ ~content:_ -> ())
    ?on_native_action
    ?on_usage_report
    ~event_bus ~raw_trace ~on_event ~config () =
  let settled_session = Atomic.make None in
  let on_session_settled value = Atomic.set settled_session (Some value) in
  let effect_disposition =
    Atomic.make Keeper_provider_attempt_effect.No_effect_observed
  in
  let observe_effect_attempted () =
    Atomic.set effect_disposition Keeper_provider_attempt_effect.Effect_attempted
  in
  let result =
    Host.with_run_lifecycle_events ~event_bus ~keeper_name (fun () ->
      run_without_lifecycle ~official_task_reference ~accepts_image_input ~on_session_settled ~official_client_continuation
        ~required_native_posture
        ~runtime_id
        ~keeper_name
        ~on_model_input_window_observation
        ~carried_front_seed
        ~librarian_front
        ~on_carried_front
        ~turn_start
    ~pre_tool_rejects
        ~base_path
        ~goal
        ~goal_blocks
        ~system_prompt
        ~tools
        ~initial_messages
        ~model_input_projection
        ~on_transmitted_model_input
        ~hooks
        ~context_injector
        ~context
        ~terminal_effect_state
        ~on_official_client_tool_boundary ~on_official_client_result_handoff ~on_native_action
        ~on_usage_report
        ~event_bus
        ~raw_trace
        ~on_event
        ~observe_effect_attempted
        ~config)
  in
  { result; settled_session = Atomic.get settled_session; effect_disposition = Atomic.get effect_disposition }
;;

module For_testing = struct
  let report_stream_usage ~turn_count ~position ~report event =
    (stream_projection
       ~keeper_name:"test"
       ~raw_trace_run:None
       ~turn_count
       ~on_native_action:None
       ~on_usage_report:(Some report)
       ~position
       None).on_runtime_event
      event
  ;;

  let project_stream events =
    let emitted = ref [] in
    let projection =
      stream_projection
        ~keeper_name:"test"
        ~raw_trace_run:None
        ~turn_count:1
        ~on_native_action:None
        ~on_usage_report:None
        ~position:Keeper_usage_resolution.Fresh
        (Some (fun event -> emitted := event :: !emitted))
    in
    List.iter projection.on_runtime_event events;
    List.rev !emitted
  ;;

  type stream_input =
    | Cli_event of Runtime_antigravity.stream_event
    | Mcp_tool_started of
        { call_id : string
        ; tool_name : string
        ; arguments : Yojson.Safe.t
        }
    | Mcp_tool_finished of { call_id : string }

  let project_stream_inputs ~during inputs =
    let emitted = ref [] in
    let feed = ref (fun (_ : stream_input) -> ()) in
    let projection =
      stream_projection
        ~keeper_name:"test"
        ~raw_trace_run:None
        ~turn_count:1
        ~on_native_action:None
        ~on_usage_report:None
        ~position:Keeper_usage_resolution.Fresh
        (Some
           (fun event ->
              emitted := event :: !emitted;
              List.iter !feed (during event)))
    in
    (feed
     := function
     | Cli_event event -> projection.on_runtime_event event
     | Mcp_tool_started { call_id; tool_name; arguments } ->
       projection.on_tool_started ~call_id ~tool_name ~arguments
     | Mcp_tool_finished { call_id } -> projection.on_tool_finished ~call_id);
    List.iter !feed inputs;
    List.rev !emitted
  ;;

  let capacity_bounded_model_input_projection =
    capacity_bounded_model_input_projection
  ;;

  let start_prompt_bytes ~system_prompt ~goal messages =
    let prepared : Host.prepared_turn =
      { messages; system_prompt; tools = []; reasoning_effort = None }
    in
    Result.map String.length (prompt_for_turn ~is_resume:false ~goal prepared)
  ;;

  let reserved_prompt_bytes ~system_prompt ~goal =
    String.length system_prompt
    + String.length goal
    + prompt_section_framing_reserved_bytes ()
  ;;

  let measure_model_input_message_bytes = measure_model_input_message_bytes
end
