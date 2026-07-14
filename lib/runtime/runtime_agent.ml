(** Runtime_agent — Config, build, and run for OAS agent execution.

    Contains the [config] type, [build], [run], and [run_with_masc_tools]
    functions. All model-selection and runtime logic lives in
    {!Runtime_observation} and {!Keeper_turn_driver}.

    @since God file decomposition — extracted from oas_worker.ml *)

type oas_tool_projector =
  name:string ->
  description:string ->
  input_schema:Yojson.Safe.t ->
  (Yojson.Safe.t -> Tool_result.result) ->
  Agent_sdk.Tool.t

let oas_tool_of_masc_hook : oas_tool_projector option ref = ref None
let set_oas_tool_of_masc_hook f = oas_tool_of_masc_hook := Some f

let oas_tool_hook_unset_error () =
  Agent_sdk.Error.Internal
    "runtime_agent_oas_tool_hook_unset: inline MASC tool projection requires \
     Tool_bridge initialization before Runtime_agent.run_with_masc_tools"
;;

let network_error_kind_of_unix_error = function
  | Unix.ECONNREFUSED | Unix.ECONNRESET -> Llm_provider.Http_client.Connection_refused
  | Unix.EPIPE -> Llm_provider.Http_client.End_of_file
  | Unix.ETIMEDOUT -> Llm_provider.Http_client.Timeout
  | Unix.ENETUNREACH | Unix.EHOSTUNREACH -> Llm_provider.Http_client.Dns_failure
  | Unix.EMFILE | Unix.ENFILE | Unix.ENOBUFS | Unix.EADDRNOTAVAIL ->
    Llm_provider.Http_client.Local_resource_exhaustion
  | _ -> Llm_provider.Http_client.Unknown
;;

let network_error_kind_of_eio_error = function
  | Eio.Net.E (Eio.Net.Connection_reset _) -> Some Llm_provider.Http_client.End_of_file
  | Eio.Net.E (Eio.Net.Connection_failure (Eio.Net.Refused _)) ->
    Some Llm_provider.Http_client.Connection_refused
  | Eio.Net.E (Eio.Net.Connection_failure Eio.Net.Timeout) ->
    Some Llm_provider.Http_client.Timeout
  | Eio.Net.E (Eio.Net.Connection_failure Eio.Net.No_matching_addresses) ->
    Some Llm_provider.Http_client.Dns_failure
  | Eio.Exn.X _ -> None
  | _ -> None
;;

let transport_error_kind_of_exception = function
  | End_of_file -> Some Llm_provider.Http_client.End_of_file
  | Eio.Time.Timeout -> Some Llm_provider.Http_client.Timeout
  | Unix.Unix_error (code, _, _) -> Some (network_error_kind_of_unix_error code)
  | Eio.Io (err, _) -> network_error_kind_of_eio_error err
  | Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _ ->
    Some Llm_provider.Http_client.Tls_error
  | Sys_error _ | Failure _ -> Some Llm_provider.Http_client.Unknown
  | _ -> None
;;

(* ================================================================ *)
(* Configuration                                                     *)
(* ================================================================ *)

type stop_reason =
  Runtime_agent_context.stop_reason =
  | Completed
  | TurnLimitObserved of { turns_used : int; limit : int }
  | ExecutionTimeoutObserved of {
      elapsed_sec : float;
      timeout_sec : float;
      turn_count : int;
      max_turns : int;
    }
  | ExecutionIdleTimeoutObserved of {
      idle_sec : float;
      idle_timeout_sec : float;
      turn_count : int;
      max_turns : int;
    }
  | Yielded_to_chat_waiting of { turns_used : int }
  | Yielded_to_durable_stimulus of { turns_used : int }
  | InputRequired of {
      turns_used : int;
      request : Agent_sdk.Error.input_required;
    }
  | ToolFailureRecoveryDeferred of {
      turns_used : int;
      reason : string;
      tool_names : string list;
    }

type config =
  Runtime_agent_context.config = {
  name : string;
  provider_cfg : Llm_provider.Provider_config.t;
  model_id : string;
  system_prompt : string;
  tools : Agent_sdk.Tool.t list;
  max_turns : int;
  max_idle_turns : int;
  stream_idle_timeout_s : float option;
  max_execution_time_s : float option;
  body_timeout_s : float option;
  max_tokens : int option;
  temperature : float option;
  hooks : Agent_sdk.Hooks.hooks option;
  event_bus : Agent_sdk.Event_bus.t option;
  session_id : string option;
  description : string option;
  initial_messages : Agent_sdk.Types.message list;
  model_input_projection
      : (Agent_sdk.Types.message list -> Agent_sdk.Types.message list) option;
  raw_trace : Agent_sdk.Raw_trace.t option;
  trace_link : (string * string) option;
  enable_thinking : bool option;
  preserve_thinking : bool option;
  transport : Masc_grpc_transport.t;
  allowed_paths : string list;
  checkpoint_sidecar : Yojson.Safe.t option;
  cache_system_prompt : bool;
  yield_on_tool : bool;
  context_injector : Agent_sdk.Hooks.context_injector option;
  context : Agent_sdk.Context.t option;
  exit_condition : (int -> bool) option;
  exit_condition_result : (int -> stop_reason * string option) option;
  thinking_budget : int option;
  top_p : float option;
  top_k : int option;
  min_p : float option;
  on_run_complete : (bool -> unit) option;
  checkpoint_sink : Agent_sdk.Agent.checkpoint_sink option;
}

let default_config = Runtime_agent_context.default_config

type run_result = {
  response : Agent_sdk.Types.api_response;
  checkpoint : Agent_sdk.Checkpoint.t option;
  session_id : string;
  turns : int;
  trace_ref : Agent_sdk.Raw_trace.run_ref option;
  run_validation : Agent_sdk.Raw_trace.run_validation option;
  runtime_observation : Runtime_observation.runtime_observation option;
  stop_reason : stop_reason;
}

type worker_lifecycle_classification =
  { event : string
  ; status : string
  ; error : string option
  }

let worker_lifecycle_classification_of_result = function
  | Ok _ -> { event = "completed"; status = "completed"; error = None }
  | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.MaxTurnsExceeded _)) ->
    { event = "completed"; status = "turn_limit_observed"; error = None }
  | Error
      (Agent_sdk.Error.Agent (Agent_sdk.Error.ToolFailureRecoveryDeferred _)) ->
    { event = "completed"; status = "tool_failure_recovery_deferred"; error = None }
  | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.InputRequired _)) ->
    { event = "completed"; status = "input_required"; error = None }
  | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.AgentExecutionTimeout _)) ->
    { event = "completed"; status = "agent_execution_timeout_observed"; error = None }
  | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.AgentExecutionIdleTimeout _)) ->
    { event = "completed"; status = "agent_idle_timeout_observed"; error = None }
  | Error e ->
    { event = "failed"; status = "failed"; error = Some (Agent_sdk.Error.to_string e) }

(* ================================================================ *)
(* Internal: resolve provider                                        *)
(* ================================================================ *)

(** Resolve a model label string to an OAS Provider.config.
    Uses MASC [Runtime_model_string.parse_model_string] (with Provider_registry as SSOT).
    Explicit model-label execution must never silently substitute a
    discovery-only model. Callers are expected to validate labels
    before reaching this helper. *)
type label_resolution_error =
  Runtime_transport.label_resolution_error =
  | Invalid_model_label of string

let label_resolution_error_to_string =
  Runtime_transport.label_resolution_error_to_string

let label_resolution_error_to_sdk_error =
  Runtime_transport.label_resolution_error_to_sdk_error

let resolve_provider_config_of_label =
  Runtime_transport.resolve_provider_config_of_label

let invalid_runtime_config =
  Runtime_transport.invalid_runtime_config

let provider_caps_of_config =
  Runtime_transport.provider_caps_of_config

let provider_supports_inline_tools =
  Runtime_transport.provider_supports_inline_tools

let provider_label =
  Runtime_transport.provider_label

let provider_resource_observation_transport
    ~(kind : Fd_accountant.kind)
    (transport : Llm_provider.Llm_transport.t)
  : Llm_provider.Llm_transport.t =
  { complete_sync =
      (fun req ->
        Fd_accountant.observe ~kind (fun () ->
          transport.complete_sync req));
    complete_stream =
      (fun ?on_telemetry ~on_event req ->
        Fd_accountant.observe ~kind (fun () ->
          transport.complete_stream ?on_telemetry ~on_event req));
  }

let provider_http_observation_transport transport =
  provider_resource_observation_transport ~kind:Provider_http transport

let observed_http_transport
    ~sw
    ~net
    ?clock
    ?body_timeout_s
    ?model_input_projection
    ()
  : Llm_provider.Llm_transport.t =
  (* RFC-OAS-026: stream_idle_timeout_s moved off transport construction
     (OAS 0.211.10 "remove implicit execution limits") and is now applied at
     the agent builder via [Agent_sdk.Builder.with_stream_idle_timeout]. The
     transport itself carries no idle deadline; OAS does not infer one. *)
  let http_transport =
    (* OAS owns stream-idle liveness on
       [Llm_transport.completion_request.stream_idle_timeout_s]. The exact
       typed provider request reaches this transport unchanged. *)
    Llm_provider.Complete.make_http_transport
      ?clock
      ?body_timeout_s
      ~sw
      ~net
      ()
  in
  let project_request
      (request : Llm_provider.Llm_transport.completion_request)
    =
    match model_input_projection with
    | None -> request
    | Some project -> { request with messages = project request.messages }
  in
  provider_http_observation_transport
    { complete_sync =
      (fun req ->
        (* RFC-0095 Phase 0 diagnostic trace — verify which transport path is invoked
           per turn for each provider. Removed at Phase 0 closeout. *)
        Log.Misc.debug
          "rfc0095-trace: runtime_runner http_transport.complete_sync invoked";
        http_transport.complete_sync (project_request req));
      complete_stream =
      (fun ?on_telemetry ~on_event req ->
        (* RFC-0095 Phase 0 diagnostic trace — verify which transport path is invoked
           per turn for each provider. Removed at Phase 0 closeout. *)
        Log.Misc.debug
          "rfc0095-trace: runtime_runner http_transport.complete_stream invoked";
        http_transport.complete_stream
          ?on_telemetry
          ~on_event
          (project_request req));
    }

let transport_for_provider
    ~sw
    ~net
    ?clock
    ?body_timeout_s
    ?model_input_projection
    ()
  =
  (* CLI subprocess transport removed (2026-05-31); every provider dispatches
     over HTTP. Runtime MCP policy is applied via the tool-lane resolver and
     per-request patching, not at transport construction, so it is no longer
     threaded here. stream_idle_timeout_s is applied at the builder, not here
     (see RFC-OAS-026 note above). *)
  Ok
    (Some
       (observed_http_transport
          ~sw
          ~net
          ?clock
          ?body_timeout_s
          ?model_input_projection
          ()))

let runtime_id_of_config (config : config) =
  let runtime_prefix = "runtime:" in
  let runtime_suffix = "/runtime" in
  match config.description with
  | Some description
    when String.starts_with ~prefix:runtime_prefix description
         && String.ends_with ~suffix:runtime_suffix description ->
      let prefix_len = String.length runtime_prefix in
      let suffix_len = String.length runtime_suffix in
      let len = String.length description - prefix_len - suffix_len in
      if len > 0 then String.sub description prefix_len len else config.name
  | _ -> config.name

let runtime_observation_for_terminal_config ~total_duration_ms ?error
    (config : config) =
  let latency_ms = Some (int_of_float total_duration_ms) in
  let capture, _metrics =
    Runtime_observation.runtime_metrics_for_candidates ~candidate_count:1 ()
  in
  Runtime_observation.record_attempt_terminal capture ~model_id:config.model_id
    ~latency_ms ~error;
  Runtime_observation.runtime_observation_with_metrics
    ~runtime_id:(runtime_id_of_config config)
    ~strategy:"single_provider_runtime"
    ~configured_labels:
      [ Runtime_observation.model_label_of_config config.provider_cfg ]
    ~candidate_count:1
    ~selected_model_raw:(Some config.model_id)
    ~capture
    ~attempt_details_source:
      (match error with
       | None -> "runtime_agent_terminal"
       | Some _ -> "runtime_agent_terminal_error")
    ()

let runtime_observation_for_completed_config ~total_duration_ms config =
  runtime_observation_for_terminal_config ~total_duration_ms config

(* RFC-OAS-026 §4.6: [read_sse] arms the stream-idle deadline only when BOTH a
   clock and the idle timeout are present. masc's clock derivation resolves to
   [None] when the process runtime is uninitialised; a [None] clock with a
   configured [stream_idle_timeout_s] would silently disarm the only
   I2-legitimate streaming timeout and let a mid-stream stall hang to the
   attempt watchdog (the exact silent no-op the RFC forbids). Fail loudly so a
   wiring regression is visible. A [None] idle (the legitimate opt-out) with a
   [None] clock stays [None]. Split into a pure decision over the two clock
   sources so the failure path is testable without an Eio runtime. *)
let decide_clock_for_idle
    ~(stream_idle_timeout_s : float option)
    ~(process_clock : (float Eio.Time.clock_ty Eio.Resource.t, string) result)
    ~(ctx_clock : float Eio.Time.clock_ty Eio.Resource.t option)
  : (float Eio.Time.clock_ty Eio.Resource.t option, Agent_sdk.Error.sdk_error) result =
  match process_clock, ctx_clock with
  | Ok c, _ -> Ok (Some c)
  | Error _, (Some _ as c) -> Ok c
  | Error e, None ->
    (match stream_idle_timeout_s with
     | Some idle ->
       Error
         (Agent_sdk.Error.Config
            (Agent_sdk.Error.InvalidConfig
               { field = "stream_idle_timeout_s"
               ; detail =
                   Printf.sprintf
                     "runtime_agent: stream_idle_timeout_s configured (%.1fs) \
                      but no clock resolvable (%s); refusing to run with a \
                      silently disarmed stream idle timeout"
                     idle
                     e
               }))
     | None -> Ok None)
;;

let resolve_clock_for_idle ~(stream_idle_timeout_s : float option) =
  decide_clock_for_idle
    ~stream_idle_timeout_s
    ~process_clock:(Process_eio.get_clock ())
    ~ctx_clock:(Eio_context.get_clock_opt ())
;;

let add_unique_string value values =
  if List.exists (String.equal value) values then values else values @ [ value ]

let rec required_modalities_of_content_blocks
    (blocks : Agent_sdk.Types.content_block list) =
  List.fold_left
    (fun acc block ->
       match block with
       | Agent_sdk.Types.Text _
       | Agent_sdk.Types.Thinking _
       | Agent_sdk.Types.ReasoningDetails _
       | Agent_sdk.Types.RedactedThinking _
       | Agent_sdk.Types.ToolUse _ ->
           acc
       | Agent_sdk.Types.Image _ -> add_unique_string "image" acc
       | Agent_sdk.Types.Document _ -> add_unique_string "document" acc
       | Agent_sdk.Types.Audio _ -> add_unique_string "audio" acc
       | Agent_sdk.Types.ToolResult { content_blocks = Some blocks; _ } ->
           List.fold_left
             (fun acc modality -> add_unique_string modality acc)
             acc
             (required_modalities_of_content_blocks blocks)
       | Agent_sdk.Types.ToolResult { content_blocks = None; _ } -> acc)
    [] blocks

let content_blocks_of_messages (messages : Agent_sdk.Types.message list) =
  List.concat_map
    (fun (message : Agent_sdk.Types.message) -> message.content)
    messages

let checkpoint_messages = function
  | None -> []
  | Some (checkpoint : Agent_sdk.Checkpoint.t) -> checkpoint.messages

let messages_for_run_with_checkpoint
    ~(checkpoint_messages : Agent_sdk.Types.message list)
    ~(initial_messages : Agent_sdk.Types.message list) =
  (* [acc @ [message]] inside a fold plus a linear [List.exists] scan makes
     this O(n^2) in the combined message count. A checkpointed run can carry
     a long conversation history, so replace both with an O(n) pass: a
     Hashtbl for O(1) average membership (structural equality, matching the
     original [( = )] semantics) and prepend-then-reverse instead of
     per-element append. *)
  let seen : (Agent_sdk.Types.message, unit) Hashtbl.t =
    Hashtbl.create (List.length initial_messages + List.length checkpoint_messages)
  in
  List.iter (fun message -> Hashtbl.replace seen message ()) initial_messages;
  let new_checkpoint_messages_rev =
    List.fold_left
      (fun acc message ->
        if Hashtbl.mem seen message
        then acc
        else (
          Hashtbl.replace seen message ();
          message :: acc))
      []
      checkpoint_messages
  in
  initial_messages @ List.rev new_checkpoint_messages_rev

let content_blocks_for_run_with_checkpoint
    ~(checkpoint_messages : Agent_sdk.Types.message list)
    ~(initial_messages : Agent_sdk.Types.message list)
    ~(goal_blocks : Agent_sdk.Types.content_block list) =
  let history_blocks =
    messages_for_run_with_checkpoint ~checkpoint_messages ~initial_messages
    |> content_blocks_of_messages
  in
  history_blocks @ goal_blocks

let content_blocks_for_run
    ~(initial_messages : Agent_sdk.Types.message list)
    ~(goal_blocks : Agent_sdk.Types.content_block list) =
  content_blocks_for_run_with_checkpoint ~checkpoint_messages:[] ~initial_messages
    ~goal_blocks

let required_modalities_of_messages (messages : Agent_sdk.Types.message list) =
  messages
  |> content_blocks_of_messages
  |> required_modalities_of_content_blocks

let required_modalities_for_run_with_checkpoint
    ~(checkpoint_messages : Agent_sdk.Types.message list)
    ~(initial_messages : Agent_sdk.Types.message list)
    ~(goal_blocks : Agent_sdk.Types.content_block list) =
  content_blocks_for_run_with_checkpoint ~checkpoint_messages ~initial_messages
    ~goal_blocks
  |> required_modalities_of_content_blocks

let required_modalities_for_run
    ~(initial_messages : Agent_sdk.Types.message list)
    ~(goal_blocks : Agent_sdk.Types.content_block list) =
  required_modalities_for_run_with_checkpoint ~checkpoint_messages:[]
    ~initial_messages ~goal_blocks

let supported_modalities_of_capabilities
    (caps : Llm_provider.Capabilities.capabilities) =
  [ "text" ]
  @ (if caps.supports_image_input then [ "image" ] else [])
  @ (if caps.supports_multimodal_inputs then [ "document" ] else [])
  @ (if caps.supports_audio_input then [ "audio" ] else [])

let supports_required_modality
    (caps : Llm_provider.Capabilities.capabilities) = function
  | "image" -> caps.supports_image_input
  | "document" -> caps.supports_multimodal_inputs
  | "audio" -> caps.supports_audio_input
  | _ -> true

let supported_non_text_capability_count
    (caps : Llm_provider.Capabilities.capabilities) =
  List.fold_left
    (fun count supported -> if supported then count + 1 else count)
    0
    [ caps.supports_image_input
    ; caps.supports_audio_input
    ; caps.supports_video_input
    ]

let supports_multimodal_bundle
    (caps : Llm_provider.Capabilities.capabilities) =
  caps.supports_multimodal_inputs || supported_non_text_capability_count caps > 1

let multimodal_capability_error ~provider_label ~required ~supported ~reason =
  let render = function
    | [] -> "none"
    | values -> String.concat "," values
  in
  Agent_sdk.Error.Config
    (Agent_sdk.Error.InvalidConfig
       { field = "multimodal_input"
       ; detail =
           Printf.sprintf
             "provider %s cannot accept requested multimodal input: %s \
              (required=%s supported=%s)"
             provider_label
             reason
             (render required)
             (render supported)
       })

(* Pure accept predicate shared by the dispatch capability gate
   ([validate_content_blocks_against_capabilities]) and the RFC-0265 modality
   reroute decision ([decide_modality_reroute]). A single predicate guarantees
   the invariant: a runtime the reroute picks as "capable" is exactly a runtime
   the gate would admit, so a reroute never lands on a runtime the gate then
   rejects. *)
let caps_admit_required_modalities
    (caps : Llm_provider.Capabilities.capabilities) (required : string list) =
  List.for_all (supports_required_modality caps) required
  && (List.length required <= 1 || supports_multimodal_bundle caps)

(* RFC-0265 follow-up — graceful media degrade. When no configured runtime can
   accept a turn's input modality (the reroute floor [No_capable_runtime]),
   instead of the loud terminal reject the caller strips the unsupported media
   blocks and proceeds on text. These helpers are the pure block/message
   filters: drop the top-level [Image]/[Document]/[Audio] blocks whose modality
   [caps] does not admit, keep everything else, and report a per-modality drop
   count for the caller's non-silent degrade reporting. ToolResult-nested media is
   left intact (rare; the capability gate floor still applies), keeping the
   strip a total function over the leaf media blocks an operator attaches. *)
let block_required_modality (block : Agent_sdk.Types.content_block) =
  match block with
  | Agent_sdk.Types.Image _ -> Some "image"
  | Agent_sdk.Types.Document _ -> Some "document"
  | Agent_sdk.Types.Audio _ -> Some "audio"
  | Agent_sdk.Types.Text _
  | Agent_sdk.Types.Thinking _
  | Agent_sdk.Types.ReasoningDetails _
  | Agent_sdk.Types.RedactedThinking _
  | Agent_sdk.Types.ToolUse _
  | Agent_sdk.Types.ToolResult _ -> None

let bump_modality_count modality counts =
  let prev = match List.assoc_opt modality counts with Some n -> n | None -> 0 in
  (modality, prev + 1) :: List.remove_assoc modality counts

let merge_modality_counts a b =
  List.fold_left
    (fun acc (modality, n) ->
       let prev =
         match List.assoc_opt modality acc with Some x -> x | None -> 0
       in
       (modality, prev + n) :: List.remove_assoc modality acc)
    a
    b

let strip_unsupported_modality_blocks
    (caps : Llm_provider.Capabilities.capabilities)
    (blocks : Agent_sdk.Types.content_block list) :
    Agent_sdk.Types.content_block list * (string * int) list =
  let kept, dropped =
    List.fold_left
      (fun (kept, dropped) block ->
         match block_required_modality block with
         | Some modality when not (supports_required_modality caps modality) ->
             (kept, bump_modality_count modality dropped)
         | _ -> (block :: kept, dropped))
      ([], [])
      blocks
  in
  (List.rev kept, dropped)

let strip_unsupported_modality_messages
    (caps : Llm_provider.Capabilities.capabilities)
    (messages : Agent_sdk.Types.message list) :
    Agent_sdk.Types.message list * (string * int) list =
  let kept, dropped =
    List.fold_left
      (fun (acc, dropped) (message : Agent_sdk.Types.message) ->
         let content, d =
           strip_unsupported_modality_blocks caps message.content
         in
         ({ message with content } :: acc, merge_modality_counts dropped d))
      ([], [])
      messages
  in
  (List.rev kept, dropped)

(* Notice text injected into a degraded turn so the model input records that media
   was dropped rather than vanishing. The keeper dispatch path owns the
   operator-visible runtime-manifest row. [None] when nothing was dropped. *)
let media_degrade_note ~(runtime_id : string) (dropped : (string * int) list) :
    string option =
  match List.fold_left (fun acc (_, n) -> acc + n) 0 dropped with
  | 0 -> None
  | total ->
      Some
        (Printf.sprintf
           "[첨부된 미디어 입력 %d건이 생략되었습니다: 현재 런타임(%s)이 이미지/문서/오디오 \
            입력을 지원하지 않아 텍스트만 전달합니다.]"
           total
           runtime_id)

let validate_content_blocks_against_capabilities
    ~(provider_label : string)
    (caps : Llm_provider.Capabilities.capabilities)
    (blocks : Agent_sdk.Types.content_block list) =
  let required = required_modalities_of_content_blocks blocks in
  let supported = supported_modalities_of_capabilities caps in
  if caps_admit_required_modalities caps required then Ok ()
  else
    match
      List.filter
        (fun modality -> not (supports_required_modality caps modality))
        required
    with
    | unsupported :: _ ->
        Error
          (multimodal_capability_error
             ~provider_label
             ~required
             ~supported
             ~reason:(Printf.sprintf "unsupported %s input" unsupported))
    | [] ->
        Error
          (multimodal_capability_error
             ~provider_label
             ~required
             ~supported
             ~reason:"provider does not support combined non-text modalities")

let validate_content_blocks_for_run_against_capabilities_with_checkpoint
    ~(provider_label : string)
    (caps : Llm_provider.Capabilities.capabilities)
    ~(checkpoint_messages : Agent_sdk.Types.message list)
    ~(initial_messages : Agent_sdk.Types.message list)
    ~(goal_blocks : Agent_sdk.Types.content_block list) =
  validate_content_blocks_against_capabilities
    ~provider_label
    caps
    (content_blocks_for_run_with_checkpoint ~checkpoint_messages ~initial_messages
       ~goal_blocks)

let validate_content_blocks_for_run_against_capabilities
    ~(provider_label : string)
    (caps : Llm_provider.Capabilities.capabilities)
    ~(initial_messages : Agent_sdk.Types.message list)
    ~(goal_blocks : Agent_sdk.Types.content_block list) =
  validate_content_blocks_for_run_against_capabilities_with_checkpoint
    ~provider_label
    caps
    ~checkpoint_messages:[]
    ~initial_messages
    ~goal_blocks

let apply_runtime_model_input_capabilities
    (caps : Llm_provider.Capabilities.capabilities)
    (model_caps : Runtime_schema.model_capabilities) =
  (* Runtime model specs are the MASC SSOT for concrete media input support.
     Provider-level caps may be broader than the selected model; media input
     must fail closed before dispatch rather than letting a provider 400 leak
     back as a late runtime error. *)
  { caps with
    supports_multimodal_inputs = model_caps.supports_multimodal_inputs;
    supports_image_input = model_caps.supports_image_input;
    supports_audio_input = model_caps.supports_audio_input;
    supports_video_input = model_caps.supports_video_input;
  }

let input_capabilities_for_config (config : config) =
  let caps = provider_caps_of_config config.provider_cfg in
  match Runtime.get_runtime_by_id (runtime_id_of_config config) with
  | None -> caps
  | Some runtime ->
      let model_caps =
        Option.value
          runtime.model.capabilities
          ~default:Runtime_schema.model_capabilities_default
      in
      apply_runtime_model_input_capabilities caps model_caps

(* Effective input capabilities of a materialized runtime (RFC-0265 reroute
   candidate scoring). Same composition as [input_capabilities_for_config]:
   provider caps overlaid with the model's declared media capabilities (the MASC
   SSOT, [apply_runtime_model_input_capabilities]). *)
let input_capabilities_of_runtime (rt : Runtime.t) =
  apply_runtime_model_input_capabilities
    (provider_caps_of_config rt.Runtime.provider_config)
    (Option.value rt.Runtime.model.capabilities
       ~default:Runtime_schema.model_capabilities_default)

(* Ordered (runtime_id, input_caps) reroute candidates: [\[runtime\].media_failover]
   order first (validated at load to resolve), then the remaining configured
   runtimes in declaration order, excluding [exclude] (the assigned runtime).
   Deterministic — no provider liveness (RFC-0260 deferred). *)
let media_reroute_candidates ~(exclude : string) :
    (string * Llm_provider.Capabilities.capabilities) list =
  let all = Runtime.get_runtimes () in
  let failover = Runtime.media_failover () in
  let by_id id =
    List.find_opt (fun (r : Runtime.t) -> String.equal r.Runtime.id id) all
  in
  let from_failover = List.filter_map by_id failover in
  let rest =
    List.filter (fun (r : Runtime.t) -> not (List.mem r.Runtime.id failover)) all
  in
  from_failover @ rest
  |> List.filter (fun (r : Runtime.t) -> not (String.equal r.Runtime.id exclude))
  |> List.map (fun (r : Runtime.t) ->
       (r.Runtime.id, input_capabilities_of_runtime r))

(* First configured runtime that admits [modality] as input, in media_failover
   order then declaration order. Reuses the RFC-0265 candidate ordering and the
   single admit predicate ([caps_admit_required_modalities]), so the pick is
   exactly a runtime the dispatch capability gate would accept (the SSOT
   invariant above). [exclude:""] = consider every configured runtime. *)
let first_media_capable_runtime ~(modality : string) : string option =
  media_reroute_candidates ~exclude:""
  |> List.find_opt (fun (_id, caps) ->
       caps_admit_required_modalities caps [ modality ])
  |> Option.map fst

let validate_content_blocks_for_config
    ?oas_checkpoint
    ~(config : config)
    (goal_blocks : Agent_sdk.Types.content_block list) =
  validate_content_blocks_for_run_against_capabilities_with_checkpoint
    ~provider_label:(provider_label config.provider_cfg)
    (input_capabilities_for_config config)
    ~checkpoint_messages:(checkpoint_messages oas_checkpoint)
    ~initial_messages:config.initial_messages
    ~goal_blocks

(* RFC-0265: capability-driven proactive runtime reroute. A pure decision from
   the turn's required input modalities and the candidate runtimes' declared
   capabilities — no I/O, no provider liveness (liveness-aware skipping is
   deferred to RFC-0260), so two identical turns reroute identically. The caller
   gathers [candidates] from the configured runtimes (media_failover order, then
   declaration order) and resolves [assigned_caps]/[candidate caps] via
   [input_capabilities_for_config]. *)
type reroute_decision =
  | No_reroute_needed
  | Reroute of { to_runtime_id : string; reason : string }
  | No_capable_runtime of { required : string list }

let decide_modality_reroute
    ~(assigned_caps : Llm_provider.Capabilities.capabilities)
    ~(required_modalities : string list)
    ~(candidates : (string * Llm_provider.Capabilities.capabilities) list) :
    reroute_decision =
  if caps_admit_required_modalities assigned_caps required_modalities then
    No_reroute_needed
  else
    match
      List.find_opt
        (fun (_id, caps) ->
          caps_admit_required_modalities caps required_modalities)
        candidates
    with
    | Some (to_runtime_id, _caps) ->
        Reroute
          { to_runtime_id
          ; reason =
              Printf.sprintf
                "assigned runtime lacks %s input"
                (String.concat "," required_modalities)
          }
    | None -> No_capable_runtime { required = required_modalities }

(* Keeper-dispatch convenience (RFC-0265): gather candidates from the runtime
   cache and decide a reroute for [assigned] given the active run view (prior
   [initial_messages] plus current [blocks]). Pure [decide_modality_reroute] over
   impure candidate gathering. *)
let decide_modality_reroute_for_runtime ~(assigned : Runtime.t)
    ?(checkpoint_messages = [])
    ?(initial_messages = [])
    (blocks : Agent_sdk.Types.content_block list) : reroute_decision =
  decide_modality_reroute
    ~assigned_caps:(input_capabilities_of_runtime assigned)
    ~required_modalities:
      (required_modalities_for_run_with_checkpoint ~checkpoint_messages ~initial_messages
         ~goal_blocks:blocks)
    ~candidates:(media_reroute_candidates ~exclude:assigned.Runtime.id)

let decide_modality_reroute_for_runtime_candidates ~(assigned : Runtime.t)
    ~(candidates : Runtime.t list)
    ?(checkpoint_messages = [])
    ?(initial_messages = [])
    (blocks : Agent_sdk.Types.content_block list) : reroute_decision =
  decide_modality_reroute
    ~assigned_caps:(input_capabilities_of_runtime assigned)
    ~required_modalities:
      (required_modalities_for_run_with_checkpoint ~checkpoint_messages
         ~initial_messages ~goal_blocks:blocks)
    ~candidates:
      (candidates
       |> List.filter (fun (runtime : Runtime.t) ->
         not (String.equal runtime.Runtime.id assigned.Runtime.id))
       |> List.map (fun (runtime : Runtime.t) ->
         runtime.Runtime.id, input_capabilities_of_runtime runtime))

let select_agent_result ~checkpoint ~resume ~build =
  match checkpoint with
  | Some checkpoint -> resume checkpoint
  | None -> build ()

module For_testing = struct
  let provider_http_observation_transport = provider_http_observation_transport
  let runtime_id_of_config = runtime_id_of_config
  let runtime_observation_for_completed_config =
    runtime_observation_for_completed_config
  let runtime_observation_for_terminal_config =
    runtime_observation_for_terminal_config
  let decide_clock_for_idle = decide_clock_for_idle
  let required_modalities_of_content_blocks = required_modalities_of_content_blocks
  let content_blocks_of_messages = content_blocks_of_messages
  let messages_for_run_with_checkpoint = messages_for_run_with_checkpoint
  let content_blocks_for_run = content_blocks_for_run
  let content_blocks_for_run_with_checkpoint =
    content_blocks_for_run_with_checkpoint
  let required_modalities_of_messages = required_modalities_of_messages
  let required_modalities_for_run = required_modalities_for_run
  let required_modalities_for_run_with_checkpoint =
    required_modalities_for_run_with_checkpoint
  let caps_admit_required_modalities = caps_admit_required_modalities
  let validate_content_blocks_for_run_against_capabilities =
    validate_content_blocks_for_run_against_capabilities
  let validate_content_blocks_for_run_against_capabilities_with_checkpoint =
    validate_content_blocks_for_run_against_capabilities_with_checkpoint
  let validate_content_blocks_against_capabilities =
    validate_content_blocks_against_capabilities
  let apply_runtime_model_input_capabilities =
    apply_runtime_model_input_capabilities
  let select_agent_result = select_agent_result
end

(* ================================================================ *)
(* Internal: event publishing                                        *)
(* ================================================================ *)

let publish_lifecycle =
  Runtime_oas_checkpoint.publish_lifecycle

let provider_lifecycle_attrs (config : config) =
  let provider_cfg = config.provider_cfg in
  let provider_kind =
    Llm_provider.Provider_config.string_of_provider_kind provider_cfg.kind
  in
  let nonempty_string key value =
    let value = String.trim value in
    if value = "" then [] else [ (key, `String value) ]
  in
  let endpoint =
    match String.trim provider_cfg.base_url, String.trim provider_cfg.request_path with
    | "", _ -> []
    | base_url, "" -> [ ("endpoint", `String base_url) ]
    | base_url, request_path -> [ ("endpoint", `String (base_url ^ request_path)) ]
  in
  [
    ("provider_kind", `String provider_kind);
    ("model_id", `String config.model_id);
    ("provider_model_id", `String provider_cfg.model_id);
  ]
  @ Runtime_max_tokens.telemetry_fields config.max_tokens
  @ nonempty_string "base_url" provider_cfg.base_url
  @ nonempty_string "request_path" provider_cfg.request_path
  @ endpoint

module Lifecycle_for_testing = struct
  let provider_attrs = provider_lifecycle_attrs
end

(* ================================================================ *)
(* Internal: checkpoint persistence                                  *)
(* ================================================================ *)

let build_checkpoint =
  Runtime_oas_checkpoint.build_checkpoint

let partial_response_of_stop =
  Runtime_oas_checkpoint.partial_response_of_stop

(* ================================================================ *)
(* Build                                                             *)
(* ================================================================ *)

let build
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
  : (Agent_sdk.Agent.t, Agent_sdk.Error.sdk_error) result =
  match resolve_clock_for_idle ~stream_idle_timeout_s:config.stream_idle_timeout_s with
  | Error _ as e -> e
  | Ok clock ->
    (match
       transport_for_provider
         ~sw
         ~net
         ?clock
         ?body_timeout_s:config.body_timeout_s
         ?model_input_projection:config.model_input_projection
         ()
     with
     | Error _ as e -> e
     | Ok transport ->
      let builder = Runtime_agent_context.builder ~net ~config ?transport () in
      Agent_sdk.Builder.build_safe builder)

let run_duration_ms_since started_at =
  Float.max 0.0 ((Unix.gettimeofday () -. started_at) *. 1000.0)

let dashboard_status_of_stop_reason = function
  | Completed -> Dashboard_oas_bridge.Success
  | TurnLimitObserved _
  | ExecutionTimeoutObserved _
  | ExecutionIdleTimeoutObserved _ -> Dashboard_oas_bridge.Success
  | Yielded_to_chat_waiting _ ->
      Dashboard_oas_bridge.Cancelled { reason = "yielded_to_chat_waiting" }
  | Yielded_to_durable_stimulus _ ->
      Dashboard_oas_bridge.Cancelled { reason = "yielded_to_durable_stimulus" }
  | InputRequired _ ->
      Dashboard_oas_bridge.Cancelled { reason = "input_required" }
  | ToolFailureRecoveryDeferred _ ->
      Dashboard_oas_bridge.Cancelled { reason = "tool_failure_recovery_deferred" }

let record_dashboard_oas_response ~config ~total_duration_ms ?serialization_ms
    ~status (response : Agent_sdk.Types.api_response) =
  try
    (* RFC-0132 PR-2: dashboard surface = external boundary; redact via SSOT. *)
    Dashboard_oas_bridge.record_response
      ~provider_id:
        (Boundary_redaction.to_string Boundary_redaction.runtime_provider_label)
      ~model_id:
        (Boundary_redaction.to_string Boundary_redaction.runtime_model_label)
      ~total_duration_ms ?serialization_ms ~status response
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Log.Misc.warn
        "oas_worker %s: dashboard_oas_bridge record failed: %s"
        config.name (Printexc.to_string exn)

let close_agent_for_cleanup ?(propagate_cancel = true) ~config agent =
  try Agent_sdk.Agent.close agent with
  | Eio.Cancel.Cancelled _ as e ->
      Log.Misc.warn
        "oas_worker %s: agent close cancelled during cleanup"
        config.name;
      if propagate_cancel then raise e
  | close_exn ->
      Log.Misc.warn "oas_worker %s: agent close failed during cleanup: %s"
        config.name (Printexc.to_string close_exn)

(* ================================================================ *)
(* Resume from checkpoint                                            *)
(* ================================================================ *)

(** Build an Agent.t from a checkpoint via [Agent.resume], overriding
    per-turn config values from the MASC config.

    The checkpoint provides: messages, turn_count, usage_stats.
    The MASC config provides: provider, model_id, system_prompt,
    temperature, tools, hooks, etc.

    @boundary-contract
    - MASC owns: per-turn config selection (model, temperature, tools,
      system_prompt), checkpoint field patching to align MASC intent with
      OAS resume semantics.
    - OAS owns: cumulative token/cost telemetry, turn_count tracking,
      Agent.resume state restoration, loop guard enforcement (max_turns,
      idle).
    - OAS no longer enforces cost or cumulative-token budgets; cost is
      observe-only telemetry. *)
let resume_from_checkpoint
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ~(checkpoint : Agent_sdk.Checkpoint.t)
  : (Agent_sdk.Agent.t, Agent_sdk.Error.sdk_error) result =
  match resolve_clock_for_idle ~stream_idle_timeout_s:config.stream_idle_timeout_s with
  | Error _ as e -> e
  | Ok clock ->
    (match
       transport_for_provider
         ~sw
         ~net
         ?clock
         ?body_timeout_s:config.body_timeout_s
         ?model_input_projection:config.model_input_projection
         ()
     with
     | Error _ as e -> e
     | Ok transport ->
      let prepared_resume =
        Runtime_agent_context.prepare_resume ~config ~checkpoint
      in
      Log.Misc.info
        "oas_worker %s: resume checkpoint_turn_count=%d turn_limit=unlimited"
        config.name checkpoint.turn_count;
      let options = { prepared_resume.options with transport } in
      Ok
        (Agent_sdk.Agent.resume ~net ~checkpoint:prepared_resume.patched_checkpoint
           ~tools:config.tools ?context:config.context
           ~provider_config:config.provider_cfg
           ~options ~config:prepared_resume.agent_config
           ?checkpoint_sink:config.checkpoint_sink
           ()))

(* ================================================================ *)
(* Run                                                               *)
(* ================================================================ *)

let content_block_detail (block : Agent_sdk.Types.content_block) =
  match block with
  | Agent_sdk.Types.Text text -> text
  | Agent_sdk.Types.Thinking _ -> "[thinking block omitted]"
  | Agent_sdk.Types.ReasoningDetails _ -> "[reasoning details block omitted]"
  | Agent_sdk.Types.RedactedThinking _ -> "[redacted thinking block omitted]"
  | _ -> (
      match Agent_sdk.Canonical_tool.tool_call_of_block block with
      | Some call ->
          Printf.sprintf "[tool use block: %s]" call.Agent_sdk.Canonical_tool.name
      | None -> (
          match block with
          | Agent_sdk.Types.ToolResult { outcome; _ } ->
              if Agent_sdk.Types.tool_result_outcome_is_error outcome
              then "[tool result block: error]"
              else "[tool result block]"
          | Agent_sdk.Types.Image { media_type; data; _ } ->
              Printf.sprintf "[image:%s data_chars=%d]" media_type (String.length data)
          | Agent_sdk.Types.Document { media_type; data; _ } ->
              Printf.sprintf "[document:%s data_chars=%d]" media_type
                (String.length data)
          | Agent_sdk.Types.Audio { media_type; data; _ } ->
              Printf.sprintf "[audio:%s data_chars=%d]" media_type (String.length data)
          | Agent_sdk.Types.Text _
          | Agent_sdk.Types.Thinking _
          | Agent_sdk.Types.ReasoningDetails _
          | Agent_sdk.Types.RedactedThinking _
          | Agent_sdk.Types.ToolUse _ ->
              invalid_arg
                "runtime_agent: OAS canonical tool-call projection unavailable"))

let content_blocks_detail (blocks : Agent_sdk.Types.content_block list) =
  blocks
  |> List.map content_block_detail
  |> String.concat "\n"
  |> String.trim

let run_blocks
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ?oas_checkpoint
    ?(on_event : (Agent_sdk.Types.sse_event -> unit) option)
    ?(on_yield : (unit -> unit) option)
    ?(on_resume : (unit -> unit) option)
    ?(agent_ref : Agent_sdk.Agent.t option ref option)
    ?goal_detail
    (goal_blocks : Agent_sdk.Types.content_block list)
  : (run_result, Agent_sdk.Error.sdk_error) result =
  match
    validate_content_blocks_for_config
      ?oas_checkpoint
      ~config
      goal_blocks
  with
  | Error _ as err -> err
  | Ok () ->
  let goal_detail =
    match goal_detail with
    | Some detail -> detail
    | None -> content_blocks_detail goal_blocks
  in
  let session_id = match config.session_id with
    | Some id -> id
    | None ->
      Printf.sprintf "%s-%d-%06x"
        config.name
        (int_of_float (Time_compat.now () *. 1000.0))
        (Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFFF)
  in
  (match config.transport with
  | Masc_grpc_transport.Local -> ()
  | t ->
    Log.Misc.info "oas_worker %s: transport=%s"
      config.name (Masc_grpc_transport.to_string t));
  publish_lifecycle ~name:config.name ~event:"build" ~detail:goal_detail
    ~attrs:(provider_lifecycle_attrs config)
    ();
  let agent_result =
    select_agent_result
      ~checkpoint:oas_checkpoint
      ~resume:(fun checkpoint ->
        resume_from_checkpoint ~sw ~net ~config ~checkpoint)
      ~build:(fun () -> build ~sw ~net ~config)
  in
  match agent_result with
  | Error e ->
    publish_lifecycle ~name:config.name ~event:"build_error"
      ~detail:(Agent_sdk.Error.to_string e)
      ~error:(Agent_sdk.Error.to_string e)
      ~status:"build_error"
      ~session_id
      ~attrs:(provider_lifecycle_attrs config)
      ();
    Error e
  | Ok agent ->
  (match agent_ref with Some r -> r := Some agent | None -> ());
  let run_started_at = Unix.gettimeofday () in
  (try
    let result =
      (* Pass the process-level Eio clock when available so agent_sdk's
         [with_optional_timeout] can fire on hang when the caller has
         also set [config.max_execution_time_s]. Both inputs must be
         [Some] for the timeout to engage; absent either, behaviour is
         historical (block until provider closes). *)
      let clock =
        match Process_eio.get_clock () with
        | Ok c -> Some c
        | Error _ -> Eio_context.get_clock_opt ()
      in
      Otel_spans.with_span
        ~name:"llm_call"
        ~attrs:[
          "gen_ai.request.model", `String config.model_id;
          "gen_ai.provider.name", `String (Llm_provider.Provider_config.string_of_provider_kind config.provider_cfg.kind);
          "masc.runtime_id", `String config.name;
        ]
        (fun _trace_id ->
          match on_event with
          | Some cb ->
              Agent_sdk.Agent.run_stream_blocks ~sw ?clock ?on_yield ?on_resume
                ~on_event:cb agent goal_blocks
          | None ->
              Agent_sdk.Agent.run_blocks ~sw ?clock ?on_yield ?on_resume agent
                goal_blocks)
    in
    let run_total_duration_ms = run_duration_ms_since run_started_at in
    let checkpoint =
      let ckpt =
        build_checkpoint ~session_id
          ?checkpoint_sidecar:config.checkpoint_sidecar agent
      in
      Some ckpt
    in
    let lifecycle = worker_lifecycle_classification_of_result result in
    publish_lifecycle ~name:config.name ~event:lifecycle.event
      ~detail:(Printf.sprintf "session=%s" session_id)
      ?error:lifecycle.error
      ~session_id
      ~status:lifecycle.status
      ~attrs:(provider_lifecycle_attrs config)
      ();
    let turns = (Agent_sdk.Agent.state agent).turn_count in
    let trace_ref = Agent_sdk.Agent.last_raw_trace_run agent in
    let close_after_success () =
      close_agent_for_cleanup ~propagate_cancel:false ~config agent
    in
    let run_validation =
      match trace_ref with
      | Some ref_ ->
        (match Agent_sdk.Raw_trace_query.validate_run ref_ with
         | Ok v -> Some v
         | Error err ->
           Log.Misc.warn "oas_worker: run_validation failed: %s"
             (Agent_sdk.Error.to_string err);
           None)
      | None -> None
    in
    (match result with
    | Ok response ->
      close_after_success ();
      record_dashboard_oas_response ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:Dashboard_oas_bridge.Success response;
      let runtime_observation =
        runtime_observation_for_completed_config
          ~total_duration_ms:run_total_duration_ms config
      in
      Ok
        {
          response;
          checkpoint;
          session_id;
          turns;
          trace_ref;
          run_validation;
          runtime_observation = Some runtime_observation;
          stop_reason = Completed;
        }
    | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.MaxTurnsExceeded r)) ->
      close_after_success ();
      Log.Misc.warn
        "oas_worker %s: observed unexpected MaxTurnsExceeded with the Keeper contract configured unbounded (turns=%d reported_limit=%d)"
        config.name
        r.turns
        r.limit;
      let partial_response =
        partial_response_of_stop
          ~session_id
          (* [MaxTurnsExceeded] carries no response payload. Do not fabricate a
             user-visible checkpoint sentence; the typed stop reason and receipt
             retain the observation while MASC treats it as non-gating. *)
          ~text:""
      in
      record_dashboard_oas_response ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:(dashboard_status_of_stop_reason
                   (TurnLimitObserved { turns_used = r.turns; limit = r.limit }))
        partial_response;
      let runtime_observation =
        runtime_observation_for_completed_config
          ~total_duration_ms:run_total_duration_ms config
      in
      Ok
        {
          response = partial_response;
          checkpoint;
          session_id;
          turns;
          trace_ref;
          run_validation;
          runtime_observation = Some runtime_observation;
          stop_reason = TurnLimitObserved { turns_used = r.turns; limit = r.limit };
        }
    | Error
        (Agent_sdk.Error.Agent (Agent_sdk.Error.InputRequired request)) ->
      close_after_success ();
      let stop_reason = InputRequired { turns_used = turns; request } in
      let partial_response =
        partial_response_of_stop ~session_id ~text:request.question
      in
      record_dashboard_oas_response
        ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:(dashboard_status_of_stop_reason stop_reason)
        partial_response;
      Log.Misc.info
        "oas_worker %s: typed input required request_id=%s turns=%d"
        config.name
        request.request_id
        turns;
      let runtime_observation =
        runtime_observation_for_completed_config
          ~total_duration_ms:run_total_duration_ms
          config
      in
      Ok
        { response = partial_response
        ; checkpoint
        ; session_id
        ; turns
        ; trace_ref
        ; run_validation
        ; runtime_observation = Some runtime_observation
        ; stop_reason
        }
    | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.ExitConditionMet r)) -> (
      match config.exit_condition_result with
      | Some render ->
        close_after_success ();
        let stop_reason, response_text_opt = render r.turn in
        let response_text =
          match response_text_opt with
          | Some text when String.trim text <> "" -> text
          | _ -> Printf.sprintf "[exit condition met at turn %d]" r.turn
        in
        let partial_response =
          partial_response_of_stop
            ~session_id
            ~text:response_text
        in
        record_dashboard_oas_response ~config
          ~total_duration_ms:run_total_duration_ms
          ~status:(dashboard_status_of_stop_reason stop_reason)
          partial_response;
        let runtime_observation =
          runtime_observation_for_completed_config
            ~total_duration_ms:run_total_duration_ms config
        in
        Ok
          {
            response = partial_response;
            checkpoint;
            session_id;
            turns;
            trace_ref;
            run_validation;
            runtime_observation = Some runtime_observation;
            stop_reason;
          }
      | None ->
        close_agent_for_cleanup ~propagate_cancel:false ~config agent;
        Error (Agent_sdk.Error.Agent (Agent_sdk.Error.ExitConditionMet r)))
    | Error
        (Agent_sdk.Error.Agent
           (Agent_sdk.Error.ToolFailureRecoveryDeferred
              { reason; tool_names })) ->
      close_after_success ();
      let stop_reason =
        ToolFailureRecoveryDeferred { turns_used = turns; reason; tool_names }
      in
      let partial_response = partial_response_of_stop ~session_id ~text:"" in
      record_dashboard_oas_response
        ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:(dashboard_status_of_stop_reason stop_reason)
        partial_response;
      Log.Misc.info
        "oas_worker %s: typed tool-failure recovery deferred tools=%s \
         reason_digest=%s"
        config.name
        (String.concat "," tool_names)
        (Auth.sha256_hash reason);
      let runtime_observation =
        runtime_observation_for_completed_config
          ~total_duration_ms:run_total_duration_ms
          config
      in
      Ok
        { response = partial_response
        ; checkpoint
        ; session_id
        ; turns
        ; trace_ref
        ; run_validation
        ; runtime_observation = Some runtime_observation
        ; stop_reason
        }
    | Error
        (Agent_sdk.Error.Agent
           (Agent_sdk.Error.AgentExecutionTimeout r)) ->
      close_after_success ();
      let partial_response =
        partial_response_of_stop
          ~session_id
          ~text:""
      in
      record_dashboard_oas_response
        ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:(dashboard_status_of_stop_reason
                   (ExecutionTimeoutObserved
                      { elapsed_sec = r.elapsed_sec
                      ; timeout_sec = r.timeout_sec
                      ; turn_count = r.turn_count
                      ; max_turns = r.max_turns
                      }))
        partial_response;
      let runtime_observation =
        runtime_observation_for_completed_config
          ~total_duration_ms:run_total_duration_ms
          config
      in
      Ok
        { response = partial_response
        ; checkpoint
        ; session_id
        ; turns
        ; trace_ref
        ; run_validation
        ; runtime_observation = Some runtime_observation
        ; stop_reason =
            ExecutionTimeoutObserved
              { elapsed_sec = r.elapsed_sec
              ; timeout_sec = r.timeout_sec
              ; turn_count = r.turn_count
              ; max_turns = r.max_turns
              }
        }
    | Error
        (Agent_sdk.Error.Agent
           (Agent_sdk.Error.AgentExecutionIdleTimeout r)) ->
      close_after_success ();
      let partial_response =
        partial_response_of_stop
          ~session_id
          ~text:""
      in
      record_dashboard_oas_response
        ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:(dashboard_status_of_stop_reason
                   (ExecutionIdleTimeoutObserved
                      { idle_sec = r.idle_sec
                      ; idle_timeout_sec = r.idle_timeout_sec
                      ; turn_count = r.turn_count
                      ; max_turns = r.max_turns
                      }))
        partial_response;
      let runtime_observation =
        runtime_observation_for_completed_config
          ~total_duration_ms:run_total_duration_ms
          config
      in
      Ok
        { response = partial_response
        ; checkpoint
        ; session_id
        ; turns
        ; trace_ref
        ; run_validation
        ; runtime_observation = Some runtime_observation
        ; stop_reason =
            ExecutionIdleTimeoutObserved
              { idle_sec = r.idle_sec
              ; idle_timeout_sec = r.idle_timeout_sec
              ; turn_count = r.turn_count
              ; max_turns = r.max_turns
              }
        }
    | Error err ->
      let detail = Agent_sdk.Error.to_string err in
      let error_response =
        partial_response_of_stop ~session_id ~text:detail
      in
      record_dashboard_oas_response ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:(Dashboard_oas_bridge.Error { transient = false })
        error_response;
      (* Demoted from WARN to DEBUG (task-239): this fires once per runtime,
         but a runtime caller (Keeper_turn_driver.run_named) retries on the
         next provider.  Emitting WARN/ERROR here creates noise on
         recovered runtimes.  The runtime layer logs [runtime-fallback] at
         INFO when it retries and emits ERROR only on full exhaustion. *)
      Log.Misc.debug "oas_worker: agent errored: %s" detail;
      close_agent_for_cleanup ~propagate_cancel:false ~config agent;
      Error err)
  with
  | Eio.Cancel.Cancelled _ as exn ->
    close_agent_for_cleanup ~propagate_cancel:false ~config agent;
    raise exn
  | exn ->
    let bt = Printexc.get_backtrace () in
    close_agent_for_cleanup ~config agent;
    let detail =
      Printf.sprintf "execution exception: %s" (Printexc.to_string exn)
    in
    let error_response =
      partial_response_of_stop ~session_id ~text:detail
    in
    record_dashboard_oas_response ~config
      ~total_duration_ms:(run_duration_ms_since run_started_at)
      ~status:(Dashboard_oas_bridge.Error { transient = false })
      error_response;
    Log.Misc.error "oas_worker %s: execution exception: %s\nBacktrace: %s"
      config.name (Printexc.to_string exn) bt;
    let typed_internal_error =
      Keeper_internal_error.Internal_unhandled_exception
        { site = Keeper_internal_error.runtime_runner_execute_site
        ; exn_repr = Printexc.to_string exn
        ; transport_error_kind = transport_error_kind_of_exception exn
        }
    in
    Error (Keeper_internal_error.sdk_error_of_masc_internal_error typed_internal_error))

let run
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ?oas_checkpoint
    ?on_event
    ?on_yield
    ?on_resume
    ?agent_ref
    (goal : string)
  : (run_result, Agent_sdk.Error.sdk_error) result =
  run_blocks ~sw ~net ~config ?oas_checkpoint ?on_event ?on_yield ?on_resume
    ?agent_ref ~goal_detail:goal [Agent_sdk.Types.Text goal]

(* ================================================================ *)
(* Convenience: run_with_masc_tools                                  *)
(* ================================================================ *)

let run_with_masc_tools
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result)
    ?on_event
    ?on_yield
    ?on_resume
    (goal : string)
  : (run_result, Agent_sdk.Error.sdk_error) result =
  match masc_tools with
  | [] ->
      run ~sw ~net ~config ?on_event ?on_yield ?on_resume goal
  | _ when provider_supports_inline_tools config.provider_cfg ->
      (match !oas_tool_of_masc_hook with
       | None -> Error (oas_tool_hook_unset_error ())
       | Some oas_tool_of_masc ->
         let oas_tools =
           List.map
             (fun (td : Masc_domain.tool_schema) ->
               oas_tool_of_masc
                 ~name:td.name
                 ~description:td.description
                 ~input_schema:td.input_schema
                 (fun input -> dispatch ~name:td.name ~args:input))
             masc_tools
         in
         let config = { config with tools = oas_tools @ config.tools } in
         run ~sw ~net ~config ?on_event ?on_yield ?on_resume goal)
  | _ ->
    Error (invalid_runtime_config "tools" "provider lacks inline tool support")
