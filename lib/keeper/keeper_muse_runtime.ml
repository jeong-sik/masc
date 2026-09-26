open Result.Syntax

module Host = Keeper_official_client_host
module Session_store = Keeper_official_client_session_store
module Serve = Runtime_muse_serve
module Msp = Runtime_muse_msp
module Mcp_http = Runtime_official_client_mcp_http

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; settled_session : Keeper_official_client_session_store.t option
  ; effect_disposition : Keeper_provider_attempt_effect.t
  }

let runtime_label = "Muse Code"

(* The provider name in errors, the config field a refusal names, and the
   attempt-details source of the runtime observation. *)
let provider_name = "muse_serve"

(* The session's MCP server name and the bridge's own name: the model sees
   MASC's tools under it. *)
let mcp_server_name = "masc"

(* The session's posture as the model meets it. Muse Code still lists
   built-in tools MASC will not approve, and a model that learns that only
   from each rejection spends calls on them. This projects the configuration
   MASC already chose ({!Runtime_muse_serve.config}), as the Codex lane's
   note does; it is not an instruction. *)
let native_posture_note = function
  | Runtime_native_tools.Native_none | Runtime_native_tools.Native_read ->
    [ Printf.sprintf
        "In this session MASC approves only the tools its %s server lists. \
         Built-in file writes and shell commands are switched off, and any \
         other call that asks for approval is rejected."
        mcp_server_name
    ]
  | Runtime_native_tools.Native_full -> []
;;

let undeclared_capacity_detail =
  "Muse Code requires max-prompt-bytes because MSP has no typed oversized-input refusal"
;;

let config_error = Host.config_error
let internal_error = Host.internal_error

(* Mirrors the Codex app-server projection where the two clients share a
   shape: an exited process and the host's own interrupt are typed MASC
   values, and an idle stream after [turn/start] was written stays off the
   rotation chain because the host may still be running the turn. *)
let runtime_error_to_core_error (error : Serve.error) =
  match error with
  | Serve.Invalid_config detail -> config_error ~field:provider_name detail
  | Serve.Spawn_failed detail ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderUnavailable { provider = provider_name; detail })
  | Serve.Turn_input_write_failed _ ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderUnavailable
         { provider = provider_name; detail = Serve.error_to_string error })
  | Serve.Protocol_error { stage; detail } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ParseError { detail = Printf.sprintf "%s: %s" stage detail })
  | Serve.Rpc_error { method_; code; message } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderReportedError
         { provider = provider_name
         ; error_type = Some "rpc_error"
         ; detail = Printf.sprintf "%s (code %d): %s" method_ code message
         })
  | Serve.Capability_not_granted _ ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderReportedError
         { provider = provider_name
         ; error_type = Some "capability_not_granted"
         ; detail = Serve.error_to_string error
         })
  | Serve.Session_model_mismatch _ ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderReportedError
         { provider = provider_name
         ; error_type = Some "session_model_mismatch"
         ; detail = Serve.error_to_string error
         })
  | Serve.Auth_required detail
  | Serve.Turn_failed { Msp.kind = Msp.Auth_required; message = detail; retryable = _ } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.AuthError { provider = provider_name; detail })
  (* [retryable] is the host's judgment that resubmitting the same input may
     succeed (msp.d.ts, [TurnError.retryable]); the provider-failure corpus
     answers a [modelError] 503 with it and then runs the next turn on the
     same session. MSP names no quota failure, so nothing here is typed
     [HardQuota]. *)
  | Serve.Turn_failed
      { Msp.kind =
          ( Msp.Step_limit
          | Msp.Config_error
          | Msp.Projection_error
          | Msp.Log_error
          | Msp.Workflow_launch_error
          | Msp.Environment_error
          | Msp.Model_error
          | Msp.Launch_error
          | Msp.Unrecognized_error_kind _ ) as kind
      ; message = _
      ; retryable
      } ->
    if retryable
    then
      Agent_core.Error.Provider
        (Llm_provider.Error.ProviderUnavailable
           { provider = provider_name; detail = Serve.error_to_string error })
    else
      Agent_core.Error.Provider
        (Llm_provider.Error.ProviderReportedError
           { provider = provider_name
           ; error_type = Some (Msp.turn_error_kind_to_string kind)
           ; detail = Serve.error_to_string error
           })
  | Serve.Turn_cancelled ->
    Keeper_internal_error.core_error_of_masc_internal_error
      (Keeper_internal_error.Host_stopped_turn
         { runtime_id = provider_name
         ; stop = Keeper_internal_error.Runtime_reported_interrupt
         })
  | Serve.Unsupported_server_request method_ ->
    Agent_core.Error.Provider
      (Llm_provider.Error.UnknownVariant
         { type_name = "muse_serve.server_request"; value = method_ })
  | Serve.Runtime_shutting_down ->
    Keeper_internal_error.core_error_of_masc_internal_error
      (Keeper_internal_error.Host_stopped_turn
         { runtime_id = provider_name
         ; stop = Keeper_internal_error.Host_graceful_shutdown
         })
  | Serve.Process_exited { status = Some Serve.Exit_session_lease_held; _ } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderTerminal
         { provider = provider_name
         ; kind = Llm_provider.Http_client.Session_conflict
         ; detail = Serve.error_to_string error
         })
  | Serve.Process_exited { status = Some Serve.Exit_config_or_credential; _ } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.AuthError
         { provider = provider_name; detail = Serve.error_to_string error })
  (* Exit 2 refuses how the host was invoked (a reasoning tier it does not
     accept among them) and exit 5 says this install serves no SDK. The same
     configuration exits the same way again, so neither is a dropped
     connection. *)
  | Serve.Process_exited
      { status = Some (Serve.Exit_usage | Serve.Exit_sdk_surface_disabled); _ } ->
    config_error ~field:provider_name (Serve.error_to_string error)
  | Serve.Process_exited
      { status =
          ( Some
              ( Serve.Exit_clean
              | Serve.Exit_unhandled
              | Serve.Exit_code _
              | Serve.Exit_signal _ )
          | None )
      ; detail = _
      ; turn_accepted
      } ->
    Keeper_internal_error.core_error_of_masc_internal_error
      (Keeper_internal_error.Runtime_connection_closed
         { runtime_id = provider_name
         ; detail = Serve.error_to_string error
         ; turn_accepted
         })
  | Serve.Timeout { seconds; turn_accepted = false } ->
    Agent_core.Error.Api
      (Agent_core.Retry.Timeout
         { message =
             Printf.sprintf "Muse Code was silent for %.3fs before turn/start" seconds
         ; phase = None
         })
  | Serve.Timeout { seconds; turn_accepted = true } ->
    Agent_core.Error.Internal
      (Printf.sprintf
         "Muse Code was silent for %.3fs after turn/start was written (not rotated: the \
          host may still be running the turn)"
         seconds)
;;

(* What the session store records when the turn fails. Every failure except
   a spawn that never started the host ends in a recovery observation, and
   the next claim then starts a fresh session. That is what a refused resume
   ([Rpc_error]), a session another process holds, or a resumed session on
   another model needs: resuming the same session again would be refused the
   same way. An exit the host documents as a refusal of its configuration,
   its credentials or its invocation is recorded as that refusal, not as a
   dropped transport. *)
let recovery_failure_of_runtime_error (error : Serve.error) =
  match error with
  | Serve.Spawn_failed _ -> Session_store.Transient_spawn_failed
  | Serve.Turn_input_write_failed _
  | Serve.Turn_cancelled
  | Serve.Runtime_shutting_down
  | Serve.Timeout _
  | Serve.Process_exited
      { status =
          ( Some
              ( Serve.Exit_clean
              | Serve.Exit_unhandled
              | Serve.Exit_code _
              | Serve.Exit_signal _ )
          | None )
      ; _
      } -> Session_store.Transport_interrupted
  | Serve.Invalid_config _
  | Serve.Protocol_error _
  | Serve.Rpc_error _
  | Serve.Capability_not_granted _
  | Serve.Unsupported_server_request _
  | Serve.Process_exited { status = Some Serve.Exit_usage; _ } -> Session_store.Protocol_failed
  | Serve.Session_model_mismatch _
  | Serve.Auth_required _
  | Serve.Turn_failed _
  | Serve.Process_exited
      { status =
          Some
            ( Serve.Exit_session_lease_held
            | Serve.Exit_config_or_credential
            | Serve.Exit_sdk_surface_disabled )
      ; _
      } -> Session_store.Provider_rejected
;;

(* How far the turn got on the host, as the serve client's callbacks report
   it. *)
type turn_admission =
  | Not_dispatched  (** The complete [turn/start] line was not written. *)
  | Dispatched  (** It was written; the host's answer was not read. *)
  | Acknowledged  (** The host answered that it started the turn. *)

(* Whether a failed attempt can no longer claim it was effect-free. Before the
   [turn/start] write completes no turn ran, except when that write broke off
   and whether the host received the turn is unknown, as on the Codex lane.
   Once it completes, the host may be running the turn: it takes a command in
   durably before it answers, its built-in tools run under rules MASC cannot
   state ({!Runtime_native_tools.muse_default}), and a subagent or workflow
   the turn starts runs its own tools in a child session this client does
   not read. Only the host's refusal of [turn/start] itself, an error answer
   to the one request then outstanding, proves that no turn ran. *)
let failure_leaves_effects_unknown ~admission (error : Serve.error) =
  match admission with
  | Acknowledged -> true
  | Dispatched ->
    (match error with
     | Serve.Rpc_error _ -> false
     | Serve.Invalid_config _
     | Serve.Spawn_failed _
     | Serve.Turn_input_write_failed _
     | Serve.Protocol_error _
     | Serve.Capability_not_granted _
     | Serve.Session_model_mismatch _
     | Serve.Auth_required _
     | Serve.Turn_failed _
     | Serve.Turn_cancelled
     | Serve.Unsupported_server_request _
     | Serve.Runtime_shutting_down
     | Serve.Process_exited _
     | Serve.Timeout _ -> true)
  | Not_dispatched ->
    (match error with
     | Serve.Turn_input_write_failed _ -> true
     | Serve.Invalid_config _
     | Serve.Spawn_failed _
     | Serve.Protocol_error _
     | Serve.Rpc_error _
     | Serve.Capability_not_granted _
     | Serve.Session_model_mismatch _
     | Serve.Auth_required _
     | Serve.Turn_failed _
     | Serve.Turn_cancelled
     | Serve.Unsupported_server_request _
     | Serve.Runtime_shutting_down
     | Serve.Process_exited _
     | Serve.Timeout _ -> false)
;;

let msp_reasoning_effort : Llm_provider.Reasoning_effort.t -> Msp.reasoning_effort
  = function
  | Llm_provider.Reasoning_effort.None_ -> Msp.Effort_none
  | Llm_provider.Reasoning_effort.Minimal -> Msp.Effort_minimal
  | Llm_provider.Reasoning_effort.Low -> Msp.Effort_low
  | Llm_provider.Reasoning_effort.Medium -> Msp.Effort_medium
  | Llm_provider.Reasoning_effort.High -> Msp.Effort_high
  | Llm_provider.Reasoning_effort.XHigh -> Msp.Effort_xhigh
  | Llm_provider.Reasoning_effort.Max -> Msp.Effort_max
;;

(* MSP's raw [TokenUsage] puts [cachedTokens] inside or beside
   [inputTokens] depending on the provider's convention (msp.d.ts,
   [TokenUsage.cachedTokens]). The counted-once prompt total is
   [promptTokens] on [session/tokenUsage], which the serve client does not
   decode, and [turn/completed] carries only the raw counters. So the cache
   split is not claimed: [inputTokens] stands as the prompt count and both
   cache slots stay zero, which never records more cache than prompt. *)
let api_usage_of_token_usage (usage : Msp.token_usage) : Agent_core.Types.api_usage =
  { input_tokens = usage.input_tokens
  ; output_tokens = usage.output_tokens
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = 0
  ; cost_usd = None
  }
;;

(* The model a Keeper row names. The host reports the session's model on
   every [session/start] and [session/resume] result; the configured id and
   then the runtime id name the row only when it does not. *)
let model_label ~runtime_id ~configured_model reported =
  match reported, configured_model with
  | Some model, (Some _ | None) -> model
  | None, Some model -> model
  | None, None -> runtime_id
;;

(* The serve client answers an approval from the posture and reports the
   decision. The tool item the request belongs to is already observed as a
   native tool, so the decision itself is logged, not counted as an action. *)
let approval_decision_label = function
  | Msp.Approved -> "approved once"
  | Msp.Approved_for_session -> "approved for the session"
  | Msp.Approved_policy_amendment -> "approved with a policy amendment"
  | Msp.Denied -> "denied"
  | Msp.Denied_policy_amendment -> "denied with a policy amendment"
  | Msp.Timed_out -> "timed out"
  | Msp.Abort -> "aborted"
  | Msp.Unrecognized_decision decision -> decision
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

(* MSP's [session/start] takes no system prompt, so the start turn frames
   it into the input the way the Antigravity lane does, with the same
   labels and separator. A keeper turn cannot start without its labels; the
   missing asset is a packaging fault, raised where the turn is framed. *)
let required_label = function
  | Ok label -> label
  | Error message -> invalid_arg message
;;

let system_instructions_label () =
  required_label (Antigravity_input_frame.system_instructions_label ())
;;

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

let reserved_prompt_bytes ~system_prompt ~goal =
  String.length system_prompt
  + String.length goal
  + prompt_section_framing_reserved_bytes ()
;;

(* The carried front is a position in durable checkpoint history, so admit it
   before the source projection appends its bounded Gate replay reference.
   The byte window runs last and charges every message that can reach the
   host. Its observation maps back to the durable history, as on the
   Antigravity lane. *)
let bounded_history_projection ~capacity_bytes ~reserved_bytes
    ?on_model_input_window_observation ?carried_front_seed ?librarian_front ?on_carried_front
    ~turn_start ~keeper_name ~runtime_id source_projection
  : Agent_core.Agent.model_input_projection
  =
  fun history_messages ->
  let* librarian_front = Host.read_librarian_front librarian_front history_messages in
  let carried_front_seed = Host.read_seed_once carried_front_seed in
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

let capacity_bounded_model_input_projection ~capacity_bytes ~system_prompt ~goal
    ?on_model_input_window_observation ?carried_front_seed ?librarian_front ?on_carried_front
    ~turn_start ~keeper_name ~runtime_id source_projection
  =
  let reserved_bytes = reserved_prompt_bytes ~system_prompt ~goal in
  if reserved_bytes >= capacity_bytes
  then
    Error
      (config_error
         ~field:"max_prompt_bytes"
         (Printf.sprintf
            "Muse Code fixed prompt sections measure %d bytes, at or above max-prompt-bytes %d"
            reserved_bytes
            capacity_bytes))
  else
    Ok
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
         source_projection)
;;

let prompt_for_turn ~is_resume ~goal (prepared : Host.prepared_turn) =
  if is_resume
  then
    (* The host session already holds the system prompt and the seeded
       history. The hook context is turn-local, so its typed carrier goes
       out again; nothing is recorded as held on this lane, so every carried
       context is sent. *)
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

let muse_dynamic_tool ~observe_effect_attempted (tool : Host.dynamic_tool) =
  { tool with
    call =
      (fun ~call_id input ->
        (* Close the outer same-turn retry boundary before entering user/tool
           code. The handler may commit and then raise or be cancelled, so
           observing only its returned value would reopen a duplicate-effect
           window. *)
        observe_effect_attempted ();
        tool.call ~call_id input)
  }
;;

let find_tool tools name =
  List.find_opt (fun (tool : Host.dynamic_tool) -> String.equal tool.name name) tools
;;

(* A session takes MASC's tools as one required streamable-HTTP server:
   a bridge the host cannot reach fails the session instead of running the
   turn without the Keeper's tools. [served] is the list the bridge answers
   [tools/list] from, so the tools a MASC-tools-only session allows are
   exactly the ones the model can see. *)
let mcp_servers_of_bridge bridge ~(served : Host.dynamic_tool list) =
  let { Mcp_http.url; headers } = Mcp_http.endpoint bridge in
  [ { Serve.name = mcp_server_name
    ; server = Msp.Streamable_http { url; headers; required = true }
    ; tool_names = List.map (fun (tool : Host.dynamic_tool) -> tool.name) served
    }
  ]
;;

type observed_turn =
  { session_id : string
  ; turn_id : string
  ; model : string option
  }

type stream_projection =
  { on_serve_event : Serve.stream_event -> unit
  ; on_tool_started :
      call_id:string -> tool_name:string -> arguments:Yojson.Safe.t -> unit
  ; on_tool_finished : call_id:string -> unit
  }

(* [muse serve]'s stdout and MASC's MCP bridge are two channels into one
   stream. The serve client emits [Turn_started] only after it reads the
   [turn/start] answer, while the host may call a MASC tool as soon as the
   turn runs, and the bridge answers it on its own fiber. A tool block
   answered first would open before the message. *)
type mcp_blocks =
  | Held of Agent_core.Types.sse_event list
      (** Blocks of tool calls answered before MessageStart, newest first. A
          turn that fails before [Turn_started] opens no message, and they
          are not streamed. *)
  | Streaming

let stream_projection ~keeper_name ~runtime_id ~configured_model ~raw_trace_run ~turn_count
    ~on_native_action ~on_usage_report ~on_turn_started ~position on_event =
  let emit event = Option.iter (fun callback -> callback event) on_event in
  let next_tool_index = ref 1 in
  let tool_indexes = Hashtbl.create 8 in
  let native_tool_indexes = Hashtbl.create 8 in
  let emit event =
    try emit event with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Log.Runtime_agent.warn
        "Muse Code Keeper stream callback raised (error=%s)"
        (Printexc.to_string exn)
  in
  let mcp_blocks = ref (Held []) in
  let emit_mcp_block event =
    match !mcp_blocks with
    | Streaming -> emit event
    | Held held -> mcp_blocks := Held (event :: held)
  in
  (* Emitting can yield to the bridge's fiber, which then holds more blocks;
     they go out in the next pass, and streaming starts only when a pass
     finds nothing held. *)
  let rec release_mcp_blocks () =
    match !mcp_blocks with
    | Streaming | Held [] -> mcp_blocks := Streaming
    | Held held ->
      mcp_blocks := Held [];
      List.iter emit (List.rev held);
      release_mcp_blocks ()
  in
  (* Each text delta names its agent-message item, so a second message in
     the turn starts its own paragraph. *)
  let text_stream = Keeper_official_client_text_stream.create ~equal:String.equal () in
  let reported_model = ref None in
  let emit_text text =
    emit
      (Agent_core.Types.ContentBlockDelta
         { index = 0; delta = Agent_core.Types.TextDelta text })
  in
  { on_serve_event =
      (function
        | Serve.Turn_started { session_id; turn_id; model } ->
          reported_model := model;
          on_turn_started { session_id; turn_id; model };
          emit
            (Agent_core.Types.MessageStart
               { id = turn_id
               ; model = model_label ~runtime_id ~configured_model model
               ; usage = None
               });
          release_mcp_blocks ()
        | Serve.Text_delta { item_id; text } ->
          emit_text
            (Keeper_official_client_text_stream.forward
               text_stream
               ~message:(Some item_id)
               text)
        | Serve.Native_tool_started observation ->
          (* MSP's [toolCall] item names no MCP server, so a call the host
             makes to MASC's own bridge arrives here too, as a built-in tool,
             beside the MCP block the bridge opened for it. Telling the two
             apart would mean matching the host's tool-name spelling. *)
          Option.iter
            (fun observe ->
               Runtime_native_tools.observe_exact_action
                 ~official_turn:turn_count
                 ~observe
                 observation)
            on_native_action;
          Host.record_raw_native_tool ~keeper_name ~raw_trace_run ~phase:`Started observation;
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
        | Serve.Native_tool_finished observation ->
          Host.record_raw_native_tool ~keeper_name ~raw_trace_run ~phase:`Finished observation;
          Option.iter
            (fun identity ->
               Option.iter
                 (fun index ->
                    Hashtbl.remove native_tool_indexes identity;
                    emit (Agent_core.Types.ContentBlockStop { index }))
                 (Hashtbl.find_opt native_tool_indexes identity))
            observation.identity
        | Serve.Approval_decided { tool_name; subject = _; decision } ->
          Log.Keeper.info
            ~keeper_name
            "%s answered an approval request for %s from the native posture: %s"
            runtime_label
            tool_name
            (approval_decision_label decision)
        | Serve.Subscription_usage_observed _ ->
          (* The host's subscription window is not recorded from here:
             Runtime_provider_usage_window has no Muse Code scope, and
             adding one with its read path is stack step 5/5. *)
          ()
        | Serve.Usage_reported { session_id; turn_id; usage } ->
          (* [turn/completed] usage is "the turn's aggregate token usage,
             summed across the turn's model completions" (msp.d.ts,
             [TurnCompletedParams.usage]), keyed as the completion hook keys
             this turn: its MSP turn id. *)
          Option.iter
            (fun report ->
               report
                 { Keeper_client_usage_report.official_turn = turn_count
                 ; response_id = turn_id
                 ; model = model_label ~runtime_id ~configured_model !reported_model
                 ; conversation_id = session_id
                 ; position
                 ; usage_scope = Runtime_usage_scope.Turn_total
                 ; count =
                     Keeper_client_usage_report.Running_count
                       (api_usage_of_token_usage usage)
                 ; vendor_total_tokens = None
                 })
            on_usage_report
        | Serve.Turn_finished { text } ->
          Option.iter
            emit_text
            (Keeper_official_client_text_stream.remainder text_stream ~final_text:text);
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
             { index; content_type = "tool_use"; tool_id = Some call_id; tool_name = Some tool_name });
        emit_mcp_block
          (Agent_core.Types.ContentBlockDelta
             { index
             ; delta = Agent_core.Types.InputJsonSnapshot (Yojson.Safe.to_string arguments)
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

let phase_name : Session_store.phase -> string = function
  | Session_store.Ready -> "Ready"
  | Session_store.Start _ -> "Start"
  | Session_store.Active _ -> "Active"
  | Session_store.Turn_inflight _ -> "Turn_inflight"
  | Session_store.Recovery_required _ -> "Recovery_required"
  | Session_store.Settled _ -> "Settled"
;;

(* Where an endpoint-backed Keeper's session works, under the runtime root
   beside the other official clients' private homes:
   [<base>/.masc/official-clients/muse/workspaces/<keeper>]. *)
let endpoint_workspace_dirs = [ "official-clients"; "muse"; "workspaces" ]

(* Owner read, write and search; nothing for group or others. *)
let private_dir_perm = 0o700
let permission_bits = 0o777

(* One level of that path: created 0700 when absent, and accepted only as a
   real directory the effective user owns with mode 0700, so no symbolic
   link or shared directory can stand in for it. *)
let ensure_private_dir path =
  let* () =
    match Unix.mkdir path private_dir_perm with
    | () -> Ok ()
    | exception Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
    | exception Unix.Unix_error (error, _, _) ->
      Error (Printf.sprintf "%s cannot be created: %s" path (Unix.error_message error))
  in
  match Unix.lstat path with
  | exception Unix.Unix_error (error, _, _) ->
    Error (Printf.sprintf "%s is unreadable: %s" path (Unix.error_message error))
  | { Unix.st_kind = Unix.S_DIR; st_uid; st_perm; _ } ->
    if st_uid <> Unix.geteuid ()
    then Error (Printf.sprintf "%s is owned by uid %d" path st_uid)
    else if st_perm land permission_bits <> private_dir_perm
    then
      Error
        (Printf.sprintf
           "%s has mode %03o, not %03o"
           path
           (st_perm land permission_bits)
           private_dir_perm)
    else Ok path
  | { Unix.st_kind =
        ( Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
        | Unix.S_SOCK )
    ; _
    } -> Error (Printf.sprintf "%s is not a real directory" path)
;;

let endpoint_workspace_root ~base_path ~keeper_name =
  let refused detail = Error (config_error ~field:"muse_workspace_root" detail) in
  if String.equal keeper_name ""
     || String.equal keeper_name Filename.current_dir_name
     || String.equal keeper_name Filename.parent_dir_name
     || not (String.equal (Filename.basename keeper_name) keeper_name)
  then refused (Printf.sprintf "Keeper name %S is not one path segment" keeper_name)
  else
    List.fold_left
      (fun parent leaf ->
         let* parent = parent in
         ensure_private_dir (Filename.concat parent leaf))
      (Ok (Common.masc_dir_from_base_path ~base_path))
      (endpoint_workspace_dirs @ [ keeper_name ])
    |> Result.fold ~ok:Result.ok ~error:refused
;;

(* MSP's one path setting is the session's [workspaceRoot], and the host's
   file tools stay inside it even with its sandbox off (Muse Code SDK
   CHANGELOG). The base path holds [.masc], auth tokens included, so the
   session never works there.

   A Docker Keeper's session works in its playground, the host root MASC's
   own file tools confine the Keeper to. The Keeper's turn creates it before
   the runtime runs ([Keeper_alerting_path.ensure_sandbox_bundle]), so a
   missing one is refused, not made here.

   A Micro_vm or Remote_ssh Keeper's working tree lives on its endpoint,
   which MASC's own tools reach and this host process does not, and its host
   root is the bookkeeping bundle. Its session works in a private directory
   of its own instead, created empty. The path depends only on the base path
   and the Keeper's name, so every turn names the same root: the root enters
   the session digest, and a changed one would start a fresh session. *)
let session_workspace_root ~base_path ~keeper_name =
  let config = Workspace.default_config base_path in
  let refused detail = Error (config_error ~field:"playground_root" detail) in
  match Keeper_meta_store.read_effective_meta_presence config keeper_name with
  | Error detail -> refused ("the Keeper meta is unreadable: " ^ detail)
  | Ok Keeper_meta_store.Meta_absent ->
    refused "the Keeper has no meta, so it has no playground"
  | Ok (Keeper_meta_store.Meta_not_current detail) ->
    refused ("the Keeper meta is not current: " ^ detail)
  | Ok (Keeper_meta_store.Meta_present meta) ->
    (match meta.Keeper_meta_contract.sandbox_profile with
     | Keeper_types_profile_sandbox.Docker ->
       let root =
         Env_config_core.strip_path_trailing_slashes
           (Keeper_sandbox.host_root_abs_of_meta ~config meta)
       in
       (match Sys.is_directory root with
        | true -> Ok root
        | false -> refused (Printf.sprintf "playground %s is not a directory" root)
        | exception Sys_error detail ->
          refused (Printf.sprintf "playground %s is unreadable: %s" root detail))
     | Keeper_types_profile_sandbox.Micro_vm | Keeper_types_profile_sandbox.Remote_ssh ->
       endpoint_workspace_root ~base_path ~keeper_name)
;;

let run_without_lifecycle ~official_task_reference ~accepts_image_input ~on_session_settled
    ~required_native_posture ~official_client_continuation ~runtime_id ~keeper_name
    ~on_model_input_window_observation ~carried_front_seed ~librarian_front ~on_carried_front
    ~turn_start ~pre_tool_rejects ~base_path ~goal ~goal_blocks ~system_prompt ~tools
    ~initial_messages ~model_input_projection ~on_transmitted_model_input ~hooks
    ~context_injector ~context ~terminal_effect_state ~event_bus ~raw_trace ~on_event
    ~observe_effect_attempted ~observe_transport_uncertain ~on_official_client_tool_boundary
    ~on_official_client_result_handoff ~on_native_action ~on_usage_report
    ~(config : Serve.config) =
  match Eio_context.get_env_opt (), Eio_context.get_clock_opt () with
  | None, _ ->
    Error
      (config_error
         ~field:"eio_env"
         "Muse Code runtime requires the initialized Eio standard environment")
  | _, None ->
    Error
      (config_error ~field:"eio_clock" "Muse Code runtime requires the initialized Eio clock")
  | Some env, Some clock ->
    (* DET-OK: a caller that installs no hooks runs the empty hook set. *)
    let hooks = Option.value hooks ~default:Agent_core.Hooks.empty in
    let owner_epoch = Session_store.process_epoch () in
    let* stored_session =
      Session_store.load ~base_path ~keeper_name
      |> Result.map_error (fun detail ->
        internal_error ("Muse Code session binding load failed: " ^ detail))
    in
    let* stored_session =
      match stored_session with
      | Some ({ phase = Start _ | Active _ | Turn_inflight _; _ } as expected) ->
        Session_store.reconcile_process_restart
          ~base_path
          ~keeper_name
          ~expected
          ~current_owner_epoch:owner_epoch
          ~required_at:(Time_compat.now ())
        |> Result.map Option.some
        |> Result.map_error (fun detail ->
          config_error ~field:"official_client_session.phase" detail)
      | None | Some { phase = Ready | Recovery_required _ | Settled _; _ } ->
        Ok stored_session
    in
    let* claim_plan =
      Session_store.plan_claim ~expected:stored_session ~client_kind:Muse ~runtime_id
      |> Result.map_error Session_store.core_error_of_claim_error
    in
    let* native_posture =
      Host.resolve_native_posture
        ~posture_source:
          (Runtime_native_tools.posture_source_of_required required_native_posture)
        ~base_path
        ~keeper_name
        ~client_label:runtime_label
        ~default:Runtime_native_tools.muse_default
        ~none_supported:Runtime_native_tools.muse_none_supported
    in
    let tool_surface_sha256 = Session_store.tool_surface_sha256 ~native_posture tools in
    let* () =
      match official_client_continuation with
      | None -> Ok ()
      | Some checkpoint ->
        Session_store.validate_continuation
          ~checkpoint
          ~expected:stored_session
          ~client_kind:Muse
          ~runtime_id
          ~tool_surface_sha256
        |> Result.map_error (config_error ~field:"official_client_session.gate_continuation")
    in
    let claim_plan = Session_store.reconcile_tool_surface claim_plan ~tool_surface_sha256 in
    let* workspace_root = session_workspace_root ~base_path ~keeper_name in
    (* MSP offers no replaceable configuration channel, and this client
       names the model and the workspace root only when it starts a session.
       A host session that settled against another canonical history, system
       prompt, configured model or root is superseded by a fresh one seeded
       from the canonical source; ephemeral world context stays on the
       per-turn prompt path. Without the model here a changed model resumed
       the old session, and the serve client refused it as
       [Session_model_mismatch]: the turn failed before the next claim started
       fresh. Without the root a resumed session kept working where it
       started. *)
    let snapshot =
      `Assoc
        [ "system_prompt", `String system_prompt
        ; ( "messages"
          , `List (List.map Keeper_official_client_context_codec.to_json initial_messages) )
        ; ( "model"
          , match config.model with
            | Some model -> `String model
            | None -> `Null )
        ; "workspace_root", `String workspace_root
        ]
    in
    let snapshot_sha256 =
      snapshot
      |> Yojson.Safe.to_string
      |> Digestif.SHA256.digest_string
      |> Digestif.SHA256.to_hex
    in
    let admission_error reason =
      config_error
        ~field:"official_client_session.context_admission"
        (Session_store.context_admission_error_to_string reason)
    in
    (* A Gate continuation is bound to its original host session: completion
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
         "muse: keeper=%s host session %s did not settle against the current canonical \
          history, system prompt and model; starting a fresh session"
         keeper_name
         session_id
     | Some _, Some _ | None, (Some _ | None) -> ());
    let claim_plan = reconciled_plan in
    let session_mode =
      match claim_plan.previous_settlement with
      | None -> Serve.Start
      | Some { session_id; _ } -> Serve.Resume { session_id }
    in
    let is_resume = Option.is_some claim_plan.previous_settlement in
    let context_frontier : Session_store.context_frontier =
      { snapshot_sha256
      ; message_count = List.length initial_messages
      ; delivery = Canonical_source_guard
      ; acknowledged_turn = None
      ; held_context = []
      }
    in
    let turn_count = claim_plan.turn_count in
    let* goal, goal_images =
      match goal_blocks with
      | None -> Ok (goal, [])
      | Some blocks -> Host.text_and_images_of_blocks ~runtime_label ~field:"goal_blocks" blocks
    in
    let* () =
      match goal_images, accepts_image_input with
      | _ :: _, false ->
        Error
          (config_error
             ~field:"goal_blocks"
             "Muse Code turn carries goal images but the runtime does not accept image input")
      | [], (true | false) | _ :: _, true -> Ok ()
    in
    let* capacity_bytes =
      match Runtime_inference.resolve_max_prompt_bytes ~runtime_id with
      | Some capacity_bytes -> Ok capacity_bytes
      | None -> Error (config_error ~field:"max_prompt_bytes" undeclared_capacity_detail)
    in
    let* () =
      match official_task_reference with
      | None -> Ok ()
      | Some _ ->
        Error
          (config_error
             ~field:"official_client_session.context_admission"
             "historical_task_reference_unavailable: this client cannot replace \
              task-reference context without replaying it as user input")
    in
    let* prepared =
      Host.prepare_turn
        ~configured_reasoning_effort:(Runtime_inference.resolve_reasoning_effort ~runtime_id)
        ~runtime_label
        ~keeper_name
        ~turn_count
        ~system_prompt:
          (system_prompt :: native_posture_note native_posture
           |> List.filter (fun text -> String.trim text <> "")
           |> String.concat "\n\n")
        ~tools
        ~initial_messages
        ~model_input_projection:(if is_resume then model_input_projection else None)
        ~hooks:(Some hooks)
    in
    let reasoning_effort =
      Host.effective_reasoning_effort
        ~runtime_label
        ~keeper_name
        ~runtime_id
        ~model_id:config.model
        ~requested:prepared.reasoning_effort
      |> Option.map msp_reasoning_effort
    in
    let* prepared =
      if is_resume
      then Ok prepared
      else
        let* capacity_projection =
          capacity_bounded_model_input_projection
            ~capacity_bytes
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
          try capacity_projection prepared.messages with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
            Error
              (internal_error
                 (runtime_label
                  ^ " runtime model input projection raised: "
                  ^ Printexc.to_string exn))
        in
        Ok { prepared with messages }
    in
    (* The prepared attribution, not transmission evidence: the serve client
       calls this only after the complete [turn/start] line is written. *)
    let report_transmitted_input () =
      match
        on_transmitted_model_input
          (if is_resume
           then Host.Held_by_client_session
           else Host.Whole_input_transmitted prepared.messages)
      with
      | () -> ()
      | exception exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        (* Entered only after a complete [turn/start] write: losing this
           observation cannot restore pre-dispatch retry safety. *)
        observe_transport_uncertain ();
        Printexc.raise_with_backtrace exn backtrace
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
                "Muse Code final prompt measures %d bytes, above max-prompt-bytes %d"
                (String.length prompt)
                capacity_bytes))
    in
    Log.Keeper.info
      ~keeper_name
      "%s turn composition: mode=%s prompt_bytes=%d system_prompt_bytes=%d goal_bytes=%d \
       images=%d declared_max_prompt_bytes=%d"
      runtime_label
      (if is_resume then "resume" else "start")
      (String.length prompt)
      (String.length prepared.system_prompt)
      (String.length goal)
      (List.length goal_images)
      capacity_bytes;
    let client_config : Serve.config =
      { config with
        native = native_posture
      ; (* A per-model [turn-timeout-s] overrides the stream-idle bound, and
           [0] removes it: the deadline notices a host that went silent, it
           does not cap legitimate work. Absent leaves the configured bound. *)
        timeout_s =
          (match Runtime_inference.resolve_turn_timeout_s ~runtime_id with
           | None -> config.timeout_s
           | Some seconds when seconds <= 0.0 -> None
           | Some seconds -> Some seconds)
      ; wall_clock_ceiling_s =
          (match Runtime_inference.resolve_wall_clock_ceiling_s ~runtime_id with
           | Some seconds -> Some seconds
           | None -> config.wall_clock_ceiling_s)
      }
    in
    let images =
      List.map
        (fun (image : Host.image_block) ->
           { Serve.media_type = image.media_type; base64_data = image.base64_data })
        goal_images
    in
    let* () =
      Serve.validate_turn ~session_mode client_config ~workspace_root ~prompt ~images
      |> Result.map_error runtime_error_to_core_error
    in
    let raw_trace_run =
      Host.start_raw_trace
        ~keeper_name
        ~raw_trace
        ~prompt
        ?model:config.model
        ?reasoning_effort:(Option.map Msp.reasoning_effort_to_string reasoning_effort)
        ()
    in
    let terminal_error = ref None in
    let* dynamic_tools =
      match
        Host.dynamic_tools
          ~content_transport:Runtime_official_client_tool.Mcp
          ~accepts_image_input
          (* The host has no place to show an operator prompt mid-turn, so a
             decision asking for one is rejected rather than admitted. *)
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
      with
      | Ok dynamic_tools -> Ok (List.map (muse_dynamic_tool ~observe_effect_attempted) dynamic_tools)
      | Error error ->
        Host.finish_raw_error ~keeper_name raw_trace_run error;
        Error error
    in
    let* claimed_session =
      match
        Session_store.claim_with_context_frontier
          ~context_frontier:(Some context_frontier)
          ~base_path
          ~keeper_name
          ~expected:stored_session
          ~client_kind:Muse
          ~owner_epoch
          ~runtime_id
          ~tool_surface_sha256
          ~updated_at:(Time_compat.now ())
      with
      | Ok session -> Ok session
      | Error detail ->
        let error = internal_error ("Muse Code session claim failed: " ^ detail) in
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
        Error (Printf.sprintf "Muse Code session %s failed: %s" label detail)
    in
    let require_recovery detail =
      match !session_state with
      | { Session_store.phase = Ready | Settled _ | Recovery_required _; _ } -> Ok ()
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
         | { phase = Ready | Settled _ | Recovery_required _; _ } -> Ok ()
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
    let process_cwd = Eio.Path.(Eio.Stdenv.fs env / workspace_root) in
    let started_at = Time_compat.now () in
    let observed_turn = ref None in
    let admission = ref Not_dispatched in
    let turn_acknowledged, acknowledge_turn = Eio.Promise.create () in
    (* The host's turn id is durable from the moment the serve client reports
       it, so a failure or a restart mid-turn leaves the recovery row naming
       the turn. The stream callback cannot fail the turn, so a failed write
       is logged here and the turn's end writes it again. *)
    let record_turn_identity ~session_id ~turn_id =
      match (!session_state).Session_store.phase with
      | Session_store.Turn_inflight
          { session_id = recorded_session; turn_id = Some recorded_turn; _ }
        when String.equal recorded_session session_id
             && String.equal recorded_turn turn_id -> Ok ()
      | Session_store.Turn_inflight
          { session_id = recorded_session; turn_id = Some recorded_turn; _ } ->
        Error
          (Printf.sprintf
             "the claim recorded turn %s in session %s, but the host reported turn %s \
              in session %s"
             recorded_turn
             recorded_session
             turn_id
             session_id)
      | Session_store.Turn_inflight { turn_id = None; _ } ->
        update_session "turn identity transition" (fun expected ->
          Session_store.mark_turn_started
            ~base_path
            ~keeper_name
            ~expected
            ~session_id
            ~turn_id
            ~turn_count
            ~updated_at:(Time_compat.now ()))
      | (Ready | Start _ | Active _ | Recovery_required _ | Settled _) as phase ->
        Error
          (Printf.sprintf
             "turn identity: expected Turn_inflight, phase is %s"
             (phase_name phase))
    in
    let stream =
      stream_projection
        ~keeper_name
        ~runtime_id
        ~configured_model:config.model
        ~raw_trace_run
        ~turn_count
        ~on_native_action
        ~on_usage_report
        ~on_turn_started:(fun turn ->
          (* From here the host runs the turn, and MASC cannot prove what it
             did. A call the host's own rules allow runs without asking
             MASC ({!Runtime_native_tools.muse_default}); a
             subagent or workflow runs its tools in a child session this
             client does not read. A failure after this point must not rotate
             into a second run of the same goal. *)
          admission := Acknowledged;
          observe_transport_uncertain ();
          observed_turn := Some turn;
          (match record_turn_identity ~session_id:turn.session_id ~turn_id:turn.turn_id with
           | Ok () -> ()
           | Error detail ->
             Log.Keeper.warn
               ~keeper_name
               "%s could not record acknowledged turn %s yet: %s"
               runtime_label
               turn.turn_id
               detail);
          match Eio.Promise.try_resolve acknowledge_turn () with
          | true | false -> ())
        ~position:
          (match session_mode with
           | Serve.Start -> Keeper_usage_resolution.Fresh
           | Serve.Resume _ -> Keeper_usage_resolution.Resumed)
        on_event
    in
    (* A host stop settles the turn the host acknowledged. The serve client
       reports its id with [Turn_started], and the stop waits for it (see the
       watcher below), so the turn id is known here. *)
    let settle_host_stop stop =
      let* session_id, turn_id, model =
        match (!session_state).Session_store.phase, !observed_turn with
        | Session_store.Turn_inflight { session_id; turn_id = Some turn_id; _ }, observed ->
          Ok
            ( session_id
            , turn_id
            , Option.bind observed (fun (observed : observed_turn) -> observed.model) )
        | Session_store.Turn_inflight { session_id; turn_id = None; _ }, Some observed
          when String.equal observed.session_id session_id ->
          Ok (session_id, observed.turn_id, observed.model)
        | Turn_inflight { session_id; turn_id = None; _ }, Some observed ->
          Error
            (internal_error
               (Printf.sprintf
                  "Muse Code host stop: the host acknowledged a turn in session %s, but \
                   the claim is on session %s"
                  observed.session_id
                  session_id))
        | Turn_inflight { turn_id = None; _ }, None ->
          Error
            (internal_error
               "Muse Code host stop arrived before the host acknowledged the turn, so no \
                turn id names what to settle")
        | (Ready | Start _ | Active _ | Recovery_required _ | Settled _), (Some _ | None) ->
          Error
            (internal_error
               (Printf.sprintf
                  "Muse Code host stop arrived without an admitted provider turn (phase \
                   %s)"
                  (phase_name (!session_state).phase)))
      in
      let* () =
        record_turn_identity ~session_id ~turn_id |> Result.map_error internal_error
      in
      let projected =
        Host.host_stop_result
          ~runtime_id
          ~model:(model_label ~runtime_id ~configured_model:config.model model)
          ~session_id
          ~turn_id
          ~turns_used:turn_count
          ~latency_ms:(Some (Int.of_float ((Time_compat.now () -. started_at) *. 1000.0)))
            (* The turn's counts arrive only with [turn/completed], which a
               host stop precedes, so no request's occupancy is known here. *)
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
          internal_error ("Muse Code host-stop settlement failed: " ^ detail))
      in
      session_state := settled;
      on_session_settled settled;
      projected
    in
    let run_client () =
      Eio.Switch.run (fun sw ->
        let abort_turn, resolve_abort_turn = Eio.Promise.create () in
        let abort_turn_resolved = Atomic.make false in
        let bridge =
          Mcp_http.start
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~secure_random:(Eio.Stdenv.secure_random env)
            ~server_name:mcp_server_name
            ~tool_specs:(fun () -> List.map tool_spec dynamic_tools)
            ~call_tool:(fun ~name ~call_id ~arguments ->
              find_tool dynamic_tools name
              |> Option.map (fun (tool : Host.dynamic_tool) ->
                stream.on_tool_started ~call_id ~tool_name:name ~arguments;
                Fun.protect
                  ~finally:(fun () -> stream.on_tool_finished ~call_id)
                  (fun () ->
                    let result = tool.call ~call_id arguments in
                    { Mcp_http.outcome = tool_result result
                    ; after_response_sent =
                        (fun () ->
                          Option.iter
                            (fun detail ->
                               if Atomic.compare_and_set abort_turn_resolved false true
                               then Eio.Promise.resolve resolve_abort_turn detail)
                            result.abort_turn)
                    })))
            ()
        in
        (* A turn the host completed as the abort arrived is a completed
           turn: its answer stands and the abort is moot.

           A MASC tool can ask for the stop before the serve client has read
           the host's [turn/start] answer: the bridge answers on its own
           fiber as soon as the host runs the turn. The stop settles the turn
           under the answer's [turnId], which MSP makes the authority ("always
           take it from the ack rather than deriving it", msp.d.ts
           [TurnStartResult.turnId]), so the watcher reports the stop only
           once that answer was read. The host writes it before it runs the
           turn, so it is already in the pipe. A turn that fails without it
           ends the work first, and the stop is moot again. *)
        match
          Watched_work.run
            (fun () ->
               `Runtime
                 (Serve.run_turn
                    ~session_mode
                    ~mcp_servers:(mcp_servers_of_bridge bridge ~served:dynamic_tools)
                    ?reasoning_effort
                    ~on_session_ready:(fun ~session_id ->
                      let* () =
                        update_session "active transition" (fun expected ->
                          Session_store.mark_active
                            ~base_path
                            ~keeper_name
                            ~expected
                            ~session_id
                            ~updated_at:(Time_compat.now ()))
                      in
                      update_session "turn-starting transition" (fun expected ->
                        Session_store.mark_turn_starting
                          ~base_path
                          ~keeper_name
                          ~expected
                          ~session_id
                          ~updated_at:(Time_compat.now ())))
                    ~on_prompt_sent:(fun () ->
                      admission := Dispatched;
                      report_transmitted_input ())
                    ~on_stream_event:stream.on_serve_event
                    ~mgr:process_mgr
                    ~clock
                    ~cwd:process_cwd
                    client_config
                    ~workspace_root
                    ~prompt
                    ~images))
            ~watcher:(fun () ->
              let stop = Eio.Promise.await abort_turn in
              Eio.Promise.await turn_acknowledged;
              `Abort stop)
        with
        | `Runtime client_result ->
          client_result
          |> Result.map (fun turn -> `Completed turn)
          |> Result.map_error (fun error ->
            if failure_leaves_effects_unknown ~admission:!admission error
            then observe_transport_uncertain ();
            recovery_failure := recovery_failure_of_runtime_error error;
            runtime_error_to_core_error error)
        | `Abort stop -> Ok (`Stopped stop))
    in
    let settle_cancellation exn =
      let backtrace = Printexc.get_raw_backtrace () in
      recovery_failure
        := (if Keeper_owner_signals.is_owner_cancel_reason exn then
              Session_store.Owner_stopped_turn
            else Session_store.Transport_interrupted);
      let detail = "Muse Code turn cancelled: " ^ Printexc.to_string exn in
      (match Eio.Cancel.protect (fun () -> settle_failed_claim detail) with
       | Ok () -> ()
       | Error recovery_detail ->
         Log.Keeper.error
           ~keeper_name
           "Muse Code cancellation recovery persistence failed: %s"
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
        | Ok (`Completed (turn : Serve.turn_result)) ->
          recovery_failure := Session_store.Protocol_failed;
          let* () =
            record_turn_identity ~session_id:turn.session_id ~turn_id:turn.turn_id
            |> Result.map_error internal_error
          in
          recovery_failure := Session_store.Host_hook_failed;
          let* () =
            match !terminal_error with
            | None -> Ok ()
            | Some detail -> Error (internal_error detail)
          in
          let latency_ms = Int.of_float ((Time_compat.now () -. started_at) *. 1000.0) in
          let model = model_label ~runtime_id ~configured_model:config.model turn.model in
          let usage_scope =
            match turn.usage with
            | Some _ -> Runtime_usage_scope.Turn_total
            | None -> Runtime_usage_scope.Usage_scope_unavailable
          in
          let response =
            { Agent_core.Types.id = turn.turn_id
            ; model
            ; stop_reason = EndTurn
            ; content = [ Text turn.text ]
            ; usage = Option.map api_usage_of_token_usage turn.usage
            ; telemetry =
                Some
                  { Agent_core.Types.default_inference_telemetry with
                    request_latency_ms = Some latency_ms
                  ; canonical_model_id = turn.model
                  ; reasoning_tokens =
                      Option.map (fun (usage : Msp.token_usage) -> usage.reasoning_tokens) turn.usage
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
              ~turn_id:turn.turn_id
              ~updated_at:(Time_compat.now ())
            |> Result.map (fun settled ->
              session_state := settled;
              on_session_settled settled)
            |> Result.map_error (fun detail ->
              internal_error ("Muse Code session settlement failed: " ^ detail))
          in
          let capture, _metrics = Runtime_observation.runtime_metrics_for_candidates () in
          Runtime_observation.record_attempt_terminal
            capture
            ~model_id:model
            ~latency_ms:(Some latency_ms)
            ~error:None;
          let runtime_observation =
            Runtime_observation.runtime_observation_with_metrics
              ~runtime_id
              ~selected_model_raw:turn.model
              ~capture
              ~attempt_details_source:provider_name
              ~agent_core_internal_runtime_allowed:false
              ~usage_scope
              ()
          in
          Ok
            { Runtime_agent.response
            ; checkpoint = None
            ; session_id = turn.session_id
            ; session_resumed = Some turn.resumed
            ; turns = turn_count
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
      | exn ->
        Llm_provider.Reserved_exn.reraise_if_reserved exn;
        (* An exception the client does not type -- the bridge failing to
           listen, for one -- still ends this claim. Left in [Start] under
           this process's epoch, it would refuse every later turn. Where it
           was raised is not known, so the claim is ambiguous, and after the
           [turn/start] write so is what the host did. *)
        recovery_failure := Session_store.Transport_interrupted;
        (match !admission with
         | Not_dispatched -> ()
         | Dispatched | Acknowledged -> observe_transport_uncertain ());
        Error (internal_error (runtime_label ^ " turn raised: " ^ Printexc.to_string exn))
    in
    match turn_result with
    | Ok result -> Ok (Host.finish_raw_success ~keeper_name raw_trace_run result)
    | Error original_error ->
      (* The claim settles before the raw trace closes, and both are shielded
         from cancellation. Closing the trace first let a cancel that landed
         there skip the settlement: the claim stayed in [Start], [Active] or
         [Turn_inflight] under this process's epoch, and
         [reconcile_process_restart] refused every later turn until a
         restart. *)
      let original_detail = Agent_core.Error.to_string original_error in
      let settled = Eio.Cancel.protect (fun () -> settle_failed_claim original_detail) in
      Eio.Cancel.protect (fun () ->
        Host.finish_raw_error ~keeper_name raw_trace_run original_error);
      (match settled with
       | Ok () -> Error original_error
       | Error recovery_detail ->
         Error
           (internal_error
              (Printf.sprintf
                 "Muse Code turn failed and recovery persistence also failed: \
                  original=%s recovery=%s"
                 original_detail
                 recovery_detail)))
;;

let run ?official_task_reference ~accepts_image_input ?required_native_posture
    ?official_client_continuation ~runtime_id ~keeper_name ~pre_tool_rejects ~base_path ~goal
    ~goal_blocks ~system_prompt ~tools ~initial_messages ~model_input_projection
    ~on_transmitted_model_input ~hooks ~context_injector ~context
    ?(terminal_effect_state = fun () -> Keeper_tools_agent_core.Terminal_effect_open)
    ?on_model_input_window_observation ?carried_front_seed ?librarian_front ?on_carried_front
    ~turn_start ?on_official_client_tool_boundary
    ?(on_official_client_result_handoff = fun ~invocation:_ ~content:_ -> ())
    ?on_native_action ?on_usage_report ~event_bus ~raw_trace ~on_event ~config () =
  let settled_session = Atomic.make None in
  let on_session_settled value = Atomic.set settled_session (Some value) in
  let effect_disposition = Atomic.make Keeper_provider_attempt_effect.No_effect_observed in
  let observe_effect_attempted () =
    Atomic.set effect_disposition Keeper_provider_attempt_effect.Effect_attempted
  in
  (* Uncertainty cannot erase stronger evidence: the compare-and-set keeps an
     effect already observed. *)
  let observe_transport_uncertain () =
    match
      Atomic.compare_and_set
        effect_disposition
        Keeper_provider_attempt_effect.No_effect_observed
        Keeper_provider_attempt_effect.Observation_unavailable
    with
    | true | false -> ()
  in
  let result =
    Host.with_run_lifecycle_events ~event_bus ~keeper_name (fun () ->
      run_without_lifecycle
        ~official_task_reference
        ~accepts_image_input
        ~on_session_settled
        ~required_native_posture
        ~official_client_continuation
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
        ~event_bus
        ~raw_trace
        ~on_event
        ~observe_effect_attempted
        ~observe_transport_uncertain
        ~on_official_client_tool_boundary
        ~on_official_client_result_handoff
        ~on_native_action
        ~on_usage_report
        ~config)
  in
  { result
  ; settled_session = Atomic.get settled_session
  ; effect_disposition = Atomic.get effect_disposition
  }
;;

module For_testing = struct
  let test_projection ~turn_count ~position ~on_usage_report on_event =
    stream_projection
      ~keeper_name:"test"
      ~runtime_id:"muse.test"
      ~configured_model:None
      ~raw_trace_run:None
      ~turn_count
      ~on_native_action:None
      ~on_usage_report
      ~on_turn_started:(fun (_ : observed_turn) -> ())
      ~position
      on_event
  ;;

  let usage_reports ~turn_count ~position events =
    let reports = ref [] in
    let projection =
      test_projection
        ~turn_count
        ~position
        ~on_usage_report:(Some (fun report -> reports := report :: !reports))
        None
    in
    List.iter projection.on_serve_event events;
    List.rev !reports
  ;;

  let project_stream events =
    let emitted = ref [] in
    let projection =
      test_projection
        ~turn_count:1
        ~position:Keeper_usage_resolution.Fresh
        ~on_usage_report:None
        (Some (fun event -> emitted := event :: !emitted))
    in
    List.iter projection.on_serve_event events;
    List.rev !emitted
  ;;

  type stream_input =
    | Serve_event of Serve.stream_event
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
      test_projection
        ~turn_count:1
        ~position:Keeper_usage_resolution.Fresh
        ~on_usage_report:None
        (Some
           (fun event ->
              (* A callback that yields before it records [event] lets the
                 bridge's fiber run first, so [during] is fed first. *)
              List.iter !feed (during event);
              emitted := event :: !emitted))
    in
    (feed
     := function
     | Serve_event event -> projection.on_serve_event event
     | Mcp_tool_started { call_id; tool_name; arguments } ->
       projection.on_tool_started ~call_id ~tool_name ~arguments
     | Mcp_tool_finished { call_id } -> projection.on_tool_finished ~call_id);
    List.iter !feed inputs;
    List.rev !emitted
  ;;

  let runtime_error_to_core_error = runtime_error_to_core_error
  let recovery_failure_of_runtime_error = recovery_failure_of_runtime_error

  let start_prompt ~system_prompt ~goal messages =
    let prepared : Host.prepared_turn =
      { messages; system_prompt; tools = []; reasoning_effort = None }
    in
    prompt_for_turn ~is_resume:false ~goal prepared
  ;;

  let reserved_prompt_bytes = reserved_prompt_bytes
  let measure_model_input_message_bytes = measure_model_input_message_bytes
  let native_posture_note = native_posture_note
end
