(** Runtime_agent — Config, build, and run for AGENT_CORE agent execution.

    Contains the [config] type, [build], [run], and [run_with_masc_tools]
    functions. All model-selection and runtime logic lives in
    {!Runtime_observation} and {!Keeper_turn_driver}.

    This module is the MASC execution boundary for Agent Core. *)

type agent_core_tool_projector =
  name:string ->
  description:string ->
  input_schema:Yojson.Safe.t ->
  (Yojson.Safe.t -> Tool_result.result) ->
  Agent_core.Tool.t

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
  | Yielded_to_operation_queued of { turns_used : int }
  | Yielded_to_durable_stimulus of { turns_used : int }
  | Yielded_after_repeated_tool_call of
      { turns_used : int
      ; tool_name : string
      ; repeated_count : int
      }
  | Yielded_after_repeated_assistant_text of
      { turns_used : int
      ; repeated_count : int
      }
  | InputRequired of {
      turns_used : int;
      request : Agent_core.Error.input_required;
    }

type cooperative_yield_reason =
  | Operation_queued
  | Durable_stimulus_waiting
  | Repeated_tool_call of
      { tool_name : string
      ; repeated_count : int
      }
  | Repeated_assistant_text of { repeated_count : int }
  | Terminal_tool_completed

type cooperative_yield_decision =
  | Continue
  | Yield of cooperative_yield_reason

type cooperative_yield_probe =
  Agent_core.Agent.Advanced.tool_boundary ->
  (cooperative_yield_decision, Agent_core.Error.t) result

type config =
  Runtime_agent_context.config = {
  name : string;
  provider_cfg : Llm_provider.Provider_config.t;
  model_id : string;
  system_prompt : string;
  tools : Agent_core.Tool.t list;
  stream_idle_timeout_s : float option;
  first_event_timeout_s : float option;
  body_timeout_s : float option;
  max_tokens : int option;
  temperature : float option;
  hooks : Agent_core.Hooks.hooks option;
  tool_approval : Agent_core.Hooks.tool_approval_callback option;
  event_bus : Agent_core.Event_bus.t option;
  session_id : string option;
  description : string option;
  runtime_id : string option;
  initial_messages : Agent_core.Types.message list;
  model_input_projection : Agent_core.Agent.model_input_projection option;
  serialization_executor : Agent_core.Agent.serialization_executor option;
  pre_dispatch_serialization_observer :
    Agent_core.Agent.pre_dispatch_serialization_observer option;
  raw_trace : Agent_core.Raw_trace.t option;
  trace_link : (string * string) option;
  enable_thinking : bool option;
  preserve_thinking : bool option;
  transport : Masc_grpc_transport.t;
  checkpoint_sidecar : Yojson.Safe.t option;
  cache_system_prompt : bool;
  yield_on_tool : bool;
  max_tool_rounds : int option;
  context_injector : Agent_core.Hooks.context_injector option;
  context : Agent_core.Context.t option;
  thinking_budget : int option;
  top_p : float option;
  top_k : int option;
  min_p : float option;
  on_run_complete : (bool -> unit) option;
  checkpoint_sink : Agent_core.Agent.checkpoint_sink option;
}

let default_config = Runtime_agent_context.default_config

type run_result = {
  response : Agent_core.Types.api_response;
  checkpoint : Agent_core.Checkpoint.t option;
  session_id : string;
  session_resumed : bool option;
  turns : int;
  trace_ref : Agent_core.Raw_trace.run_ref option;
  run_validation : Agent_core.Raw_trace.run_validation option;
  runtime_observation : Runtime_observation.runtime_observation option;
  stop_reason : stop_reason;
}

(* ================================================================ *)
(* Internal: resolve provider                                        *)
(* ================================================================ *)

(** Resolve a model label string to an AGENT_CORE Provider.config.
    Uses MASC [Runtime_model_string.parse_model_string] (with Provider_registry as SSOT).
    Explicit model-label execution must never silently substitute a
    discovery-only model. Callers are expected to validate labels
    before reaching this helper. *)
let label_resolution_error_to_string =
  Runtime_transport.label_resolution_error_to_string

let label_resolution_error_to_core_error =
  Runtime_transport.label_resolution_error_to_core_error

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
    ()
  : Llm_provider.Llm_transport.t =
  (* Agent Core contract: stream_idle_timeout_s moved off transport construction
     (AGENT_CORE 0.211.10 "remove implicit execution limits") and is now applied at
     the agent builder via [Agent_core.Builder.with_stream_idle_timeout]. The
     transport itself carries no idle deadline; AGENT_CORE does not infer one. *)
  let http_transport =
    (* AGENT_CORE owns stream-idle liveness on
       [Llm_transport.completion_request.stream_idle_timeout_s]. The exact
       typed provider request reaches this transport unchanged. *)
    Llm_provider.Complete.make_http_transport
      ?clock
      ?body_timeout_s
      ~sw
      ~net
      ()
  in
  provider_http_observation_transport
    { complete_sync =
      (fun req ->
        (* RFC-0095 Phase 0 diagnostic trace — verify which transport path is invoked
           per turn for each provider. Removed at Phase 0 closeout. *)
        Log.Runtime_agent.debug
          "rfc0095-trace: runtime_runner http_transport.complete_sync invoked";
        http_transport.complete_sync req);
      complete_stream =
      (fun ?on_telemetry ~on_event req ->
        (* RFC-0095 Phase 0 diagnostic trace — verify which transport path is invoked
           per turn for each provider. Removed at Phase 0 closeout. *)
        Log.Runtime_agent.debug
          "rfc0095-trace: runtime_runner http_transport.complete_stream invoked";
        http_transport.complete_stream
          ?on_telemetry
          ~on_event
          req);
    }

let transport_for_provider
    ~sw
    ~net
    ?clock
    ?body_timeout_s
    ()
  =
  (* CLI subprocess transport removed (2026-05-31); every provider dispatches
     over HTTP. Runtime MCP policy is applied via the tool-lane resolver and
     per-request patching, not at transport construction, so it is no longer
     threaded here. stream_idle_timeout_s is applied at the builder, not here
     (see Agent Core contract note above). *)
  Ok
    (Some
       (observed_http_transport
          ~sw
          ~net
          ?clock
          ?body_timeout_s
          ()))

(* Typed field first (RFC-0371 B12): the id used to be recovered by parsing
   the "runtime:<id>/runtime" spelling the producer had printed into the
   human-facing [description]. The description is display-only now. *)
let runtime_id_of_config (config : config) =
  match config.runtime_id with
  | Some runtime_id -> runtime_id
  | None -> config.name

let runtime_observation_for_terminal_config ~total_duration_ms ?error
    ?(usage_scope = Runtime_usage_scope.Usage_scope_unavailable)
    (config : config) =
  let latency_ms = Some (int_of_float total_duration_ms) in
  let capture, _metrics =
    Runtime_observation.runtime_metrics_for_candidates ()
  in
  Runtime_observation.record_attempt_terminal capture ~model_id:config.model_id
    ~latency_ms ~error;
  Runtime_observation.runtime_observation_with_metrics
    ~runtime_id:(runtime_id_of_config config)
    ~selected_model_raw:(Some config.model_id)
    ~capture
    ~attempt_details_source:
      (match error with
       | None -> "runtime_agent_terminal"
       | Some _ -> "runtime_agent_terminal_error")
    ~usage_scope
    ()

let runtime_observation_for_completed_config ~total_duration_ms ~usage_scope config =
  runtime_observation_for_terminal_config ~total_duration_ms ~usage_scope config

(* Agent Core contract §4.6: [read_sse] arms the stream-idle deadline only when BOTH a
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
    ~(first_event_timeout_s : float option)
    ~(process_clock : (float Eio.Time.clock_ty Eio.Resource.t, string) result)
    ~(ctx_clock : float Eio.Time.clock_ty Eio.Resource.t option)
  : (float Eio.Time.clock_ty Eio.Resource.t option, Agent_core.Error.t) result =
  match process_clock, ctx_clock with
  | Ok c, _ -> Ok (Some c)
  | Error _, (Some _ as c) -> Ok c
  | Error e, None ->
    (match stream_idle_timeout_s, first_event_timeout_s with
     | Some idle, _ ->
       Error
         (Agent_core.Error.Config
            (Agent_core.Error.InvalidConfig
               { field = "stream_idle_timeout_s"
               ; detail =
                   Printf.sprintf
                     "runtime_agent: stream_idle_timeout_s configured (%.1fs) \
                      but no clock resolvable (%s); refusing to run with a \
                      silently disarmed stream idle timeout"
                     idle
                     e
               }))
     | None, Some first_event ->
       (* The first-event (TTFT/prefill) bound has the same clock dependency
          as the idle bound (RFC-AC-037): AGENT_CORE arms it only when a
          clock is present, so a missing clock would silently disarm it. *)
       Error
         (Agent_core.Error.Config
            (Agent_core.Error.InvalidConfig
               { field = "first_event_timeout_s"
               ; detail =
                   Printf.sprintf
                     "runtime_agent: first_event_timeout_s configured (%.1fs) \
                      but no clock resolvable (%s); refusing to run with a \
                      silently disarmed first-event timeout"
                     first_event
                     e
               }))
     | None, None -> Ok None)
;;

let resolve_clock_for_idle
    ~(stream_idle_timeout_s : float option)
    ~(first_event_timeout_s : float option)
  =
  decide_clock_for_idle
    ~stream_idle_timeout_s
    ~first_event_timeout_s
    ~process_clock:(Process_eio.get_clock ())
    ~ctx_clock:(Eio_context.get_clock_opt ())
;;

let add_unique_string value values =
  if List.exists (String.equal value) values then values else values @ [ value ]

let rec required_modalities_of_content_blocks
    (blocks : Agent_core.Types.content_block list) =
  List.fold_left
    (fun acc block ->
       match block with
       | Agent_core.Types.Text _
       | Agent_core.Types.Thinking _
       | Agent_core.Types.ReasoningDetails _
       | Agent_core.Types.RedactedThinking _
       | Agent_core.Types.ToolUse _ ->
           acc
       | Agent_core.Types.Image _ -> add_unique_string "image" acc
       | Agent_core.Types.Document _ -> add_unique_string "document" acc
       | Agent_core.Types.Audio _ -> add_unique_string "audio" acc
       | Agent_core.Types.ToolResult { content_blocks = Some blocks; _ } ->
           List.fold_left
             (fun acc modality -> add_unique_string modality acc)
             acc
             (required_modalities_of_content_blocks blocks)
       | Agent_core.Types.ToolResult { content_blocks = None; _ } -> acc)
    [] blocks

let content_blocks_of_messages (messages : Agent_core.Types.message list) =
  List.concat_map
    (fun (message : Agent_core.Types.message) -> message.content)
    messages

let checkpoint_messages = function
  | None -> []
  | Some (checkpoint : Agent_core.Checkpoint.t) -> checkpoint.messages

let messages_for_run_with_checkpoint
    ~(checkpoint_messages : Agent_core.Types.message list)
    ~(initial_messages : Agent_core.Types.message list) =
  (* [acc @ [message]] inside a fold plus a linear [List.exists] scan makes
     this O(n^2) in the combined message count. A checkpointed run can carry
     a long conversation history, so replace both with an O(n) pass: a
     Hashtbl for O(1) average membership (structural equality, matching the
     original [( = )] semantics) and prepend-then-reverse instead of
     per-element append. *)
  let seen : (Agent_core.Types.message, unit) Hashtbl.t =
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
    ~(checkpoint_messages : Agent_core.Types.message list)
    ~(initial_messages : Agent_core.Types.message list)
    ~(goal_blocks : Agent_core.Types.content_block list) =
  let history_blocks =
    messages_for_run_with_checkpoint ~checkpoint_messages ~initial_messages
    |> content_blocks_of_messages
  in
  history_blocks @ goal_blocks

let content_blocks_for_run
    ~(initial_messages : Agent_core.Types.message list)
    ~(goal_blocks : Agent_core.Types.content_block list) =
  content_blocks_for_run_with_checkpoint ~checkpoint_messages:[] ~initial_messages
    ~goal_blocks

let required_modalities_of_messages (messages : Agent_core.Types.message list) =
  messages
  |> content_blocks_of_messages
  |> required_modalities_of_content_blocks

let required_modalities_for_run_with_checkpoint
    ~(checkpoint_messages : Agent_core.Types.message list)
    ~(initial_messages : Agent_core.Types.message list)
    ~(goal_blocks : Agent_core.Types.content_block list) =
  content_blocks_for_run_with_checkpoint ~checkpoint_messages ~initial_messages
    ~goal_blocks
  |> required_modalities_of_content_blocks

let required_modalities_for_run
    ~(initial_messages : Agent_core.Types.message list)
    ~(goal_blocks : Agent_core.Types.content_block list) =
  required_modalities_for_run_with_checkpoint ~checkpoint_messages:[]
    ~initial_messages ~goal_blocks

let supported_modalities_of_capabilities
    (caps : Llm_provider.Capabilities.capabilities) =
  [ "text" ]
  @ (if caps.supports_image_input then [ "image" ] else [])
  @ (if caps.supports_multimodal_inputs then [ "document" ] else [])
  @ (if caps.supports_audio_input then [ "audio" ] else [])

(* The modality a content block demands of a runtime. The producers
   ([required_modalities_of_content_blocks], [strip_unsupported_modality_blocks])
   match exhaustively over [content_block], so the set is closed — it travels as a
   string only because the capability count list and the public
   [strip_unsupported_modality_blocks] surface are keyed by string. Parsing it
   back here keeps the decision below exhaustive: the catch-all lives at the
   parse boundary, not in the capability logic. *)
type required_modality =
  | Modality_text
  | Modality_image
  | Modality_document
  | Modality_audio

let required_modality_of_string = function
  | "text" -> Some Modality_text
  | "image" -> Some Modality_image
  | "document" -> Some Modality_document
  | "audio" -> Some Modality_audio
  | _ -> None

(* An unrecognised modality reports unsupported rather than supported. The
   previous [_ -> true] was the permissive-default shape: a string the
   producers never emit could only arrive through producer/consumer drift, and
   answering "supported" would send a block the runtime cannot handle to the
   provider. Answering "unsupported" routes it into the media reroute and
   degrade paths that already exist, so the drift is visible. Unreachable
   today — every producer emits one of the four above. *)
let supports_required_modality
    (caps : Llm_provider.Capabilities.capabilities) modality =
  match required_modality_of_string modality with
  | Some Modality_text -> true
  | Some Modality_image -> caps.supports_image_input
  | Some Modality_document -> caps.supports_multimodal_inputs
  | Some Modality_audio -> caps.supports_audio_input
  | None -> false

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
  Agent_core.Error.Config
    (Agent_core.Error.InvalidConfig
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
   count for the caller's non-silent degrade reporting. The strip descends into
   [ToolResult.content_blocks] because [required_modalities_of_content_blocks]
   descends there too: when the two disagreed, a turn whose only media sat inside
   a tool result required the image modality yet dropped nothing, so the degrade
   produced no note and the caller fell through to the provider gate with the
   media still attached. Both walks now cover the same blocks, so a modality
   this module reports as required is a modality this function can remove. *)
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

let rec strip_unsupported_modality_blocks
    (caps : Llm_provider.Capabilities.capabilities)
    (blocks : Agent_core.Types.content_block list) :
    Agent_core.Types.content_block list * (string * int) list =
  let keep_or_drop modality block kept dropped =
    if supports_required_modality caps modality then (block :: kept, dropped)
    else (kept, bump_modality_count modality dropped)
  in
  let kept, dropped =
    List.fold_left
      (fun (kept, dropped) (block : Agent_core.Types.content_block) ->
         match block with
         | Agent_core.Types.Image _ -> keep_or_drop "image" block kept dropped
         | Agent_core.Types.Document _ ->
             keep_or_drop "document" block kept dropped
         | Agent_core.Types.Audio _ -> keep_or_drop "audio" block kept dropped
         | Agent_core.Types.ToolResult
             { tool_use_id; content; outcome; json
             ; content_blocks = Some nested } ->
             let nested_kept, nested_dropped =
               strip_unsupported_modality_blocks caps nested
             in
             ( Agent_core.Types.ToolResult
                 { tool_use_id
                 ; content
                 ; outcome
                 ; json
                 ; content_blocks = Some nested_kept }
               :: kept
             , merge_modality_counts dropped nested_dropped )
         | Agent_core.Types.ToolResult { content_blocks = None; _ }
         | Agent_core.Types.Text _
         | Agent_core.Types.Thinking _
         | Agent_core.Types.ReasoningDetails _
         | Agent_core.Types.RedactedThinking _
         | Agent_core.Types.ToolUse _ -> (block :: kept, dropped))
      ([], [])
      blocks
  in
  (List.rev kept, dropped)

let strip_unsupported_modality_messages
    (caps : Llm_provider.Capabilities.capabilities)
    (messages : Agent_core.Types.message list) :
    Agent_core.Types.message list * (string * int) list =
  let kept, dropped =
    List.fold_left
      (fun (acc, dropped) (message : Agent_core.Types.message) ->
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
    (blocks : Agent_core.Types.content_block list) =
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
    ~(checkpoint_messages : Agent_core.Types.message list)
    ~(initial_messages : Agent_core.Types.message list)
    ~(goal_blocks : Agent_core.Types.content_block list) =
  validate_content_blocks_against_capabilities
    ~provider_label
    caps
    (content_blocks_for_run_with_checkpoint ~checkpoint_messages ~initial_messages
       ~goal_blocks)

let validate_content_blocks_for_run_against_capabilities
    ~(provider_label : string)
    (caps : Llm_provider.Capabilities.capabilities)
    ~(initial_messages : Agent_core.Types.message list)
    ~(goal_blocks : Agent_core.Types.content_block list) =
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
  let provider_caps =
    match rt.Runtime.execution with
    | Runtime_execution.Agent_core provider_config ->
      provider_caps_of_config provider_config
    | Runtime_execution.Codex_app_server _
    | Runtime_execution.Claude_code _
    | Runtime_execution.Antigravity_cli _ ->
      Llm_provider.Capabilities.default_capabilities
  in
  apply_runtime_model_input_capabilities
    provider_caps
    (Option.value rt.Runtime.model.capabilities
       ~default:Runtime_schema.model_capabilities_default)

let validate_content_blocks_for_config
    ?agent_core_checkpoint
    ~(config : config)
    (goal_blocks : Agent_core.Types.content_block list) =
  validate_content_blocks_for_run_against_capabilities_with_checkpoint
    ~provider_label:(provider_label config.provider_cfg)
    (input_capabilities_for_config config)
    ~checkpoint_messages:(checkpoint_messages agent_core_checkpoint)
    ~initial_messages:config.initial_messages
    ~goal_blocks

(* RFC-0265: capability-driven proactive runtime reroute. A pure decision from
   the turn's required input modalities and the candidate runtimes' declared
   capabilities — no I/O, no provider liveness (liveness-aware skipping is
   deferred to RFC-0260), so two identical turns reroute identically. The caller
   gathers [candidates] from the configured runtimes (media_failover order, then
   declaration order) and resolves [assigned_caps]/[candidate caps] via
   [input_capabilities_for_config]. *)
(* ['target] is what a reroute names. The capability-level decision below names a
   runtime id ([string]); the keeper-dispatch decision names an already-resolved
   [Runtime.t]. Keeping them one type but two instantiations means the dispatch
   path cannot be handed a decision it still has to look up: the runtime the
   decision selected is the runtime the caller dispatches to. The type is
   [private] in the .mli, so [Reroute] exists only where this module builds it —
   a reroute-to-self is not something another module can hand the driver. *)
type 'target reroute_decision =
  | No_reroute_needed
  | Reroute of { target : 'target; reason : string }
  | No_capable_runtime of { required : string list }

let reroute_reason (required_modalities : string list) =
  Printf.sprintf
    "assigned runtime lacks %s input"
    (String.concat "," required_modalities)

let decide_modality_reroute
    ~(assigned_caps : Llm_provider.Capabilities.capabilities)
    ~(required_modalities : string list)
    ~(candidates : (string * Llm_provider.Capabilities.capabilities) list) :
    string reroute_decision =
  if caps_admit_required_modalities assigned_caps required_modalities then
    No_reroute_needed
  else
    match
      List.find_opt
        (fun (_id, caps) ->
          caps_admit_required_modalities caps required_modalities)
        candidates
    with
    | Some (target, _caps) ->
        Reroute { target; reason = reroute_reason required_modalities }
    | None -> No_capable_runtime { required = required_modalities }

(* The eligible set is built by removing [assigned] first, and the reroute target
   is taken from that set — so the decision cannot name the runtime it is
   rerouting away from, and there is no id left over for a caller to re-resolve
   into some other runtime. The previous shape returned the winning id as a bare
   string and left [Runtime.get_runtime_by_id] to the driver, whose [None] arm
   silently kept the runtime that could not accept the turn. *)
let decide_modality_reroute_for_runtime_candidates ~(assigned : Runtime.t)
    ~(candidates : Runtime.t list)
    ?(checkpoint_messages = [])
    ?(initial_messages = [])
    (blocks : Agent_core.Types.content_block list) :
    Runtime.t reroute_decision =
  let required_modalities =
    required_modalities_for_run_with_checkpoint ~checkpoint_messages
      ~initial_messages ~goal_blocks:blocks
  in
  if
    caps_admit_required_modalities
      (input_capabilities_of_runtime assigned)
      required_modalities
  then No_reroute_needed
  else
    let eligible =
      List.filter
        (fun (runtime : Runtime.t) ->
          not (String.equal runtime.Runtime.id assigned.Runtime.id))
        candidates
    in
    match
      List.find_opt
        (fun (runtime : Runtime.t) ->
          caps_admit_required_modalities
            (input_capabilities_of_runtime runtime)
            required_modalities)
        eligible
    with
    | Some target ->
        Reroute { target; reason = reroute_reason required_modalities }
    | None -> No_capable_runtime { required = required_modalities }

let select_agent_result ~checkpoint ~resume ~build =
  match checkpoint with
  | Some checkpoint -> resume checkpoint
  | None -> build ()

let stop_reason_of_cooperative_yield ~turns_used = function
  | Operation_queued -> Yielded_to_operation_queued { turns_used }
  | Durable_stimulus_waiting ->
    Yielded_to_durable_stimulus { turns_used }
  | Repeated_tool_call { tool_name; repeated_count } ->
    Yielded_after_repeated_tool_call
      { turns_used; tool_name; repeated_count }
  | Repeated_assistant_text { repeated_count } ->
    Yielded_after_repeated_assistant_text { turns_used; repeated_count }
  (* The provider loop yielded at AGENT_CORE's durable post-tool boundary because
     the typed reply effect already completed. This is successful completion,
     not a continuation checkpoint that should replay on the next cycle. *)
  | Terminal_tool_completed -> Completed
;;

let cooperative_boundary_callback
      ~probe_error
      ~yield_decision
      (probe : cooperative_yield_probe)
      (boundary : Agent_core.Agent.Advanced.tool_boundary)
  =
  match probe boundary with
  | Ok Continue -> Agent_core.Agent.Advanced.Continue
  | Ok (Yield reason) ->
    yield_decision := Some reason;
    Agent_core.Agent.Advanced.Yield
  | Error error ->
    probe_error := Some error;
    Agent_core.Agent.Advanced.Yield
;;

let prefer_cooperative_probe_error probe_error advanced_result =
  match probe_error with
  | Some error -> Error error
  | None -> advanced_result
;;

module For_testing = struct
  let runtime_observation_for_completed_config =
    runtime_observation_for_completed_config
  let runtime_observation_for_terminal_config =
    runtime_observation_for_terminal_config
  let decide_clock_for_idle = decide_clock_for_idle
  let required_modalities_of_content_blocks = required_modalities_of_content_blocks
  let messages_for_run_with_checkpoint = messages_for_run_with_checkpoint
  let content_blocks_for_run = content_blocks_for_run
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
  let stop_reason_of_cooperative_yield = stop_reason_of_cooperative_yield
end

(* ================================================================ *)
(* Internal: checkpoint persistence                                  *)
(* ================================================================ *)

let build_checkpoint =
  Runtime_agent_checkpoint.build_checkpoint

let partial_response_of_stop =
  Runtime_agent_checkpoint.partial_response_of_stop

(* ================================================================ *)
(* Build                                                             *)
(* ================================================================ *)

let build
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
  : (Agent_core.Agent.t, Agent_core.Error.t) result =
  match
    resolve_clock_for_idle
      ~stream_idle_timeout_s:config.stream_idle_timeout_s
      ~first_event_timeout_s:config.first_event_timeout_s
  with
  | Error _ as e -> e
  | Ok clock ->
    (match
       transport_for_provider
         ~sw
         ~net
         ?clock
         ?body_timeout_s:config.body_timeout_s
         ()
     with
     | Error _ as e -> e
     | Ok transport ->
      let builder = Runtime_agent_context.builder ~net ~config ?transport () in
      Agent_core.Builder.build_safe builder)

let run_duration_ms_since started_at =
  Float.max 0.0 ((Unix.gettimeofday () -. started_at) *. 1000.0)

let dashboard_status_of_stop_reason = function
  | Completed -> Dashboard_agent_core_bridge.Success
  | Yielded_to_operation_queued _ ->
      Dashboard_agent_core_bridge.Cancelled { reason = "yielded_to_operation_queued" }
  | Yielded_to_durable_stimulus _ ->
      Dashboard_agent_core_bridge.Cancelled { reason = "yielded_to_durable_stimulus" }
  | Yielded_after_repeated_tool_call _ ->
      Dashboard_agent_core_bridge.Cancelled
        { reason = "yielded_after_repeated_tool_call" }
  | Yielded_after_repeated_assistant_text _ ->
      Dashboard_agent_core_bridge.Cancelled
        { reason = "yielded_after_repeated_assistant_text" }
  | InputRequired _ ->
      Dashboard_agent_core_bridge.Cancelled { reason = "input_required" }

let record_dashboard_agent_core_response ~config ~total_duration_ms ?serialization_ms
    ~status (response : Agent_core.Types.api_response) =
  try
    (* RFC-0132 PR-2: dashboard surface = external boundary; redact via SSOT. *)
    Dashboard_agent_core_bridge.record_response
      ~provider_id:
        (Boundary_redaction.to_string Boundary_redaction.runtime_provider_label)
      ~model_id:
        (Boundary_redaction.to_string Boundary_redaction.runtime_model_label)
      ~total_duration_ms ?serialization_ms ~status response
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Log.Runtime_agent.warn
        "%s: dashboard agent record failed: %s"
        config.name (Printexc.to_string exn)

let close_agent_for_cleanup ?(propagate_cancel = true) ~config agent =
  try Agent_core.Agent.close agent with
  | Eio.Cancel.Cancelled _ as e ->
      Log.Runtime_agent.warn
        "%s: agent close cancelled during cleanup"
        config.name;
      if propagate_cancel then raise e
  | close_exn ->
      Log.Runtime_agent.warn "%s: agent close failed during cleanup: %s"
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
      AGENT_CORE resume semantics.
    - AGENT_CORE owns: cumulative token/cost telemetry, turn_count tracking, and
      Agent.resume state restoration.
    - AGENT_CORE no longer enforces cost or cumulative-token budgets; cost is
      observe-only telemetry. *)
let resume_from_checkpoint
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ~(checkpoint : Agent_core.Checkpoint.t)
  : (Agent_core.Agent.t, Agent_core.Error.t) result =
  match
    resolve_clock_for_idle
      ~stream_idle_timeout_s:config.stream_idle_timeout_s
      ~first_event_timeout_s:config.first_event_timeout_s
  with
  | Error _ as e -> e
  | Ok clock ->
    (match
       transport_for_provider
         ~sw
         ~net
         ?clock
         ?body_timeout_s:config.body_timeout_s
         ()
     with
     | Error _ as e -> e
     | Ok transport ->
      let prepared_resume =
        Runtime_agent_context.prepare_resume ~config ~checkpoint
      in
      (* [turn_limit=unlimited] used to ride on this line. Nothing in the
         runtime agent or in [Agent_core.Agent.resume] carries a turn limit,
         so the field asserted a configuration that has no producer — 256 of
         these lines in the two hours to 2026-08-22T02:03Z all repeated it. *)
      Log.Runtime_agent.info
        "%s: resume checkpoint_turn_count=%d"
        config.name checkpoint.turn_count;
      let options = { prepared_resume.options with transport } in
      Ok
        (Agent_core.Agent.resume ~net ~checkpoint:prepared_resume.patched_checkpoint
           ~tools:config.tools ?context:config.context
           ~context_fit_admission:prepared_resume.context_fit_admission
           ?model_input_projection:config.model_input_projection
           ?pre_dispatch_serialization_observer:
             config.pre_dispatch_serialization_observer
           ?serialization_executor:config.serialization_executor
           ~options ~config:prepared_resume.agent_config
           ?checkpoint_sink:config.checkpoint_sink
           ()))

type classified_advanced_outcome =
  | Advanced_completed of Agent_core.Types.api_response
  | Advanced_yielded of
      cooperative_yield_reason
      * Agent_core.Agent.Advanced.yielded
      * Agent_core.Types.api_response

let classify_advanced_outcome ~yield_reason ~boundary_response outcome =
  match outcome with
  | Agent_core.Agent.Advanced.Completed response ->
    Ok (Advanced_completed response)
  | Agent_core.Agent.Advanced.Terminal_tool_completed { receipt; _ } ->
    (* The run ended because a terminal-contract tool completed its effect;
       the receipt's provider response is the completion payload — the same
       classification Agent Core's own lifecycle events apply. *)
    Ok (Advanced_completed receipt.Agent_core.Terminal_tool_receipt.response)
  | Agent_core.Agent.Advanced.Yielded yielded ->
    (match yield_reason, boundary_response with
     | Some reason, Some response ->
       Ok (Advanced_yielded (reason, yielded, response))
     | None, _ ->
       Error
         (Agent_core.Error.Internal
            "cooperative yield returned without a typed decision")
     | Some _, None ->
       Error
         (Agent_core.Error.Internal
            "cooperative yield returned without its provider response"))

(* ================================================================ *)
(* Run                                                               *)
(* ================================================================ *)

let config_with_boundary_response_capture
      (config : config)
      response_ref
  =
  let capture =
    { Agent_core.Hooks.empty with
      after_turn =
        Some
          (function
            | Agent_core.Hooks.AfterTurn { response; _ } ->
              response_ref := Some response;
              Agent_core.Hooks.Continue
            | _ -> Agent_core.Hooks.Continue)
    }
  in
  let hooks =
    match config.hooks with
    | None -> capture
    | Some hooks -> Agent_core.Hooks.compose ~outer:hooks ~inner:capture
  in
  { config with hooks = Some hooks }
;;

type run_input =
  | New_input of Agent_core.Types.content_block list
  | Continue_from_checkpoint

let run_blocks_internal
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ?agent_core_checkpoint
    ?(on_event : (Agent_core.Types.sse_event -> unit) option)
    ?(on_yield : (unit -> unit) option)
    ?(on_resume : (unit -> unit) option)
    ?(agent_ref : Agent_core.Agent.t option ref option)
    ?cooperative_yield_probe
    ~(run_input : run_input)
    (goal_blocks : Agent_core.Types.content_block list)
  : (run_result, Agent_core.Error.t) result =
  match
    validate_content_blocks_for_config
      ?agent_core_checkpoint
      ~config
      goal_blocks
  with
  | Error _ as err -> err
  | Ok () ->
  let boundary_response = ref None in
  let config =
    match cooperative_yield_probe with
    | None -> config
    | Some _ -> config_with_boundary_response_capture config boundary_response
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
    Log.Runtime_agent.info "%s: transport=%s"
      config.name (Masc_grpc_transport.to_string t));
  let agent_result =
    select_agent_result
      ~checkpoint:agent_core_checkpoint
      ~resume:(fun checkpoint ->
        resume_from_checkpoint ~sw ~net ~config ~checkpoint)
      ~build:(fun () -> build ~sw ~net ~config)
  in
  match agent_result with
  | Error e -> Error e
  | Ok agent ->
  (match agent_ref with Some r -> r := Some agent | None -> ());
  let run_started_at = Unix.gettimeofday () in
  (try
    let result =
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
          let boundary_probe = cooperative_yield_probe in
          match boundary_probe with
            | None ->
              (match run_input with
               | New_input goal_blocks ->
                 (match on_event with
                  | Some cb ->
                    Agent_core.Agent.run_stream_blocks
                      ~sw
                      ?clock
                      ?on_yield
                      ?on_resume
                      ~on_event:cb
                      agent
                      goal_blocks
                  | None ->
                    Agent_core.Agent.run_blocks
                      ~sw
                      ?clock
                      ?on_yield
                      ?on_resume
                      agent
                      goal_blocks)
                 |> Result.map (fun response -> `Completed response)
               | Continue_from_checkpoint ->
                 let api_strategy =
                   match on_event with
                   | None -> Agent_core.Agent.Sync
                   | Some on_event ->
                     let on_telemetry =
                       Option.map
                         (fun bus ->
                            Agent_core.Telemetry_bus.publish
                              (Agent_core.Telemetry_bus.of_event_bus bus))
                         (Agent_core.Agent.options agent).event_bus
                     in
                     Agent_core.Agent.Stream { on_event; on_telemetry }
                 in
                 (match
                    Agent_core.Agent.Advanced.continue
                      ~sw
                      ?clock
                      ?on_yield
                      ?on_resume
                      ~api_strategy
                      ~on_tool_boundary:(fun _ -> Agent_core.Agent.Advanced.Continue)
                      agent
                  with
                  | Ok (Agent_core.Agent.Advanced.Completed response) ->
                    Ok (`Completed response)
                  | Ok
                      (Agent_core.Agent.Advanced.Terminal_tool_completed completion)
                    ->
                    Ok (`Completed completion.receipt.response)
                  | Ok (Agent_core.Agent.Advanced.Yielded _) ->
                    Error
                      (Agent_core.Error.Internal
                         "checkpoint continuation yielded without a cooperative probe")
                  | Error _ as error -> error))
            | Some probe ->
              let probe_error = ref None in
              let yield_decision = ref None in
              let on_tool_boundary =
                cooperative_boundary_callback ~probe_error ~yield_decision probe
              in
              let api_strategy =
                match on_event with
                | None -> Agent_core.Agent.Sync
                | Some on_event ->
                  let on_telemetry =
                    Option.map
                      (fun bus ->
                         Agent_core.Telemetry_bus.publish
                           (Agent_core.Telemetry_bus.of_event_bus bus))
                      (Agent_core.Agent.options agent).event_bus
                  in
                  Agent_core.Agent.Stream { on_event; on_telemetry }
              in
              let advanced_result =
                match run_input with
                | New_input goal_blocks ->
                  Agent_core.Agent.Advanced.run_blocks
                    ~sw
                    ?clock
                    ?on_yield
                    ?on_resume
                    ~api_strategy
                    ~on_tool_boundary
                    agent
                    goal_blocks
                | Continue_from_checkpoint ->
                  Agent_core.Agent.Advanced.continue
                    ~sw
                    ?clock
                    ?on_yield
                    ?on_resume
                    ~api_strategy
                    ~on_tool_boundary
                    agent
              in
              (match
                 prefer_cooperative_probe_error !probe_error advanced_result
               with
               | Error e -> Error e
               | Ok outcome ->
                 (match
                    classify_advanced_outcome
                      ~yield_reason:!yield_decision
                      ~boundary_response:!boundary_response
                      outcome
                  with
                  | Error e -> Error e
                  | Ok (Advanced_completed response) -> Ok (`Completed response)
                  | Ok (Advanced_yielded (reason, yielded, response)) ->
                    Ok (`Yielded (reason, yielded, response)))))
    in
    let run_total_duration_ms = run_duration_ms_since run_started_at in
    let checkpoint =
      match result with
      | Ok (`Yielded (_, yielded, _)) ->
        Some
          { yielded.checkpoint with
            Agent_core.Checkpoint.session_id
          ; working_context =
              (match config.checkpoint_sidecar with
               | Some _ as sidecar -> sidecar
               | None -> yielded.checkpoint.working_context)
          }
      | Ok (`Completed _) | Error _ ->
        Some
          (build_checkpoint
             ~session_id
             ?checkpoint_sidecar:config.checkpoint_sidecar
             agent)
    in
    let turns = (Agent_core.Agent.state agent).turn_count in
    let trace_ref = Agent_core.Agent.last_raw_trace_run agent in
    let close_after_success () =
      close_agent_for_cleanup ~propagate_cancel:false ~config agent
    in
    let run_validation =
      match trace_ref with
      | Some ref_ ->
        (match Agent_core.Raw_trace_query.validate_run ref_ with
         | Ok v -> Some v
         | Error err ->
           Log.Runtime_agent.warn "run_validation failed: %s"
             (Agent_core.Error.to_string err);
           None)
      | None -> None
    in
    (match result with
    | Ok (`Completed response) ->
      close_after_success ();
      record_dashboard_agent_core_response ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:Dashboard_agent_core_bridge.Success response;
      let runtime_observation =
        runtime_observation_for_completed_config
          ~total_duration_ms:run_total_duration_ms config
          ~usage_scope:
            (if Option.is_some response.usage
             then Runtime_usage_scope.Per_request
             else Runtime_usage_scope.Usage_scope_unavailable)
      in
      Ok
        {
          response;
          checkpoint;
          session_id;
          session_resumed = None;
          turns;
          trace_ref;
          run_validation;
          runtime_observation = Some runtime_observation;
          stop_reason = Completed;
        }
    | Ok (`Yielded (decision, yielded, response)) ->
      close_after_success ();
      let stop_reason =
        stop_reason_of_cooperative_yield
          ~turns_used:yielded.turn
          decision
      in
      record_dashboard_agent_core_response
        ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:(dashboard_status_of_stop_reason stop_reason)
        response;
      let runtime_observation =
        runtime_observation_for_completed_config
          ~total_duration_ms:run_total_duration_ms
          config
          ~usage_scope:
            (if Option.is_some response.usage
             then Runtime_usage_scope.Per_request
             else Runtime_usage_scope.Usage_scope_unavailable)
      in
      Ok
        { response
        ; checkpoint
        ; session_id
        ; session_resumed = None
        ; turns = yielded.turn
        ; trace_ref
        ; run_validation
        ; runtime_observation = Some runtime_observation
        ; stop_reason
        }
    | Error
        (Agent_core.Error.Agent (Agent_core.Error.InputRequired request)) ->
      close_after_success ();
      let stop_reason = InputRequired { turns_used = turns; request } in
      let partial_response =
        partial_response_of_stop ~session_id ~text:request.question
      in
      record_dashboard_agent_core_response
        ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:(dashboard_status_of_stop_reason stop_reason)
        partial_response;
      Log.Runtime_agent.info
        "%s: typed input required request_id=%s turns=%d"
        config.name
        request.request_id
        turns;
      let runtime_observation =
        runtime_observation_for_completed_config
          ~total_duration_ms:run_total_duration_ms
          config
          ~usage_scope:Runtime_usage_scope.Usage_scope_unavailable
      in
      Ok
        { response = partial_response
        ; checkpoint
        ; session_id
        ; session_resumed = None
        ; turns
        ; trace_ref
        ; run_validation
        ; runtime_observation = Some runtime_observation
        ; stop_reason
        }
    | Error err ->
      let detail = Agent_core.Error.to_string err in
      let error_response =
        partial_response_of_stop ~session_id ~text:detail
      in
      record_dashboard_agent_core_response ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:(Dashboard_agent_core_bridge.Error { transient = false })
        error_response;
      (* Demoted from WARN to DEBUG (task-239): this fires once per runtime,
         but a runtime caller (Keeper_turn_driver.run_named) retries on the
         next provider.  Emitting WARN/ERROR here creates noise on
         recovered runtimes.  The runtime layer logs [runtime-fallback] at
         INFO when it retries and emits ERROR only on full exhaustion. *)
      Log.Runtime_agent.debug "agent errored: %s" detail;
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
    record_dashboard_agent_core_response ~config
      ~total_duration_ms:(run_duration_ms_since run_started_at)
      ~status:(Dashboard_agent_core_bridge.Error { transient = false })
      error_response;
    Log.Runtime_agent.error "%s: execution exception: %s\nBacktrace: %s"
      config.name (Printexc.to_string exn) bt;
    let typed_internal_error =
      Keeper_internal_error.Internal_unhandled_exception
        { site = Keeper_internal_error.runtime_runner_execute_site
        ; exn_repr = Printexc.to_string exn
        ; transport_error_kind = transport_error_kind_of_exception exn
        }
    in
    Error (Keeper_internal_error.core_error_of_masc_internal_error typed_internal_error))

let run_blocks
    ~sw
    ~net
    ~config
    ?agent_core_checkpoint
    ?on_event
    ?on_yield
    ?on_resume
    ?agent_ref
    ?cooperative_yield_probe
    goal_blocks
  =
  run_blocks_internal
    ~sw
    ~net
    ~config
    ?agent_core_checkpoint
    ?on_event
    ?on_yield
    ?on_resume
    ?agent_ref
    ?cooperative_yield_probe
    ~run_input:(New_input goal_blocks)
    goal_blocks

let continue_from_checkpoint
    ~sw
    ~net
    ~config
    ~checkpoint
    ?on_event
    ?on_yield
    ?on_resume
    ?agent_ref
    ?cooperative_yield_probe
    ()
  =
  run_blocks_internal
    ~sw
    ~net
    ~config
    ~agent_core_checkpoint:checkpoint
    ?on_event
    ?on_yield
    ?on_resume
    ?agent_ref
    ?cooperative_yield_probe
    ~run_input:Continue_from_checkpoint
    []

let run
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ?agent_core_checkpoint
    ?on_event
    ?on_yield
    ?on_resume
    ?agent_ref
    ?cooperative_yield_probe
    (goal : string)
  : (run_result, Agent_core.Error.t) result =
  run_blocks ~sw ~net ~config ?agent_core_checkpoint ?on_event ?on_yield ?on_resume
    ?agent_ref ?cooperative_yield_probe [Agent_core.Types.Text goal]

(* ================================================================ *)
(* Convenience: run_with_masc_tools                                  *)
(* ================================================================ *)

let run_with_masc_tools
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result)
    ~(agent_core_tool_of_masc : agent_core_tool_projector)
    ?on_event
    ?on_yield
    ?on_resume
    (goal : string)
  : (run_result, Agent_core.Error.t) result =
  match masc_tools with
  | [] ->
      run ~sw ~net ~config ?on_event ?on_yield ?on_resume goal
  | _ when provider_supports_inline_tools config.provider_cfg ->
      (let agent_core_tools =
           List.map
             (fun (td : Masc_domain.tool_schema) ->
               agent_core_tool_of_masc
                 ~name:td.name
                 ~description:td.description
                 ~input_schema:td.input_schema
                 (fun input -> dispatch ~name:td.name ~args:input))
             masc_tools
         in
         let config = { config with tools = agent_core_tools @ config.tools } in
         run ~sw ~net ~config ?on_event ?on_yield ?on_resume goal)
  | _ ->
    Error (invalid_runtime_config "tools" "provider lacks inline tool support")
