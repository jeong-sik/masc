(** Runtime_agent — Config, build, and run for OAS agent execution.

    Contains the [config] type, [build], [run], and [run_with_masc_tools]
    functions. All model-selection and runtime logic lives in
    {!Runtime_observation} and {!Keeper_turn_driver}.

    @since God file decomposition — extracted from oas_worker.ml *)

let oas_tool_of_masc_hook = ref (fun ~name:_ ~description:_ ~input_schema:_ _handler -> failwith "oas_tool_of_masc_hook is not set")
let set_oas_tool_of_masc_hook f = oas_tool_of_masc_hook := f

(* ================================================================ *)
(* Configuration                                                     *)
(* ================================================================ *)

type stop_reason =
  Runtime_agent_context.stop_reason =
  | Completed
  | TurnBudgetExhausted of { turns_used : int; limit : int }
  | MutationBoundaryReached of { turns_used : int; tool_name : string option }

type config =
  Runtime_agent_context.config = {
  name : string;
  provider_cfg : Llm_provider.Provider_config.t;
  provider : Agent_sdk.Provider.config;
  model_id : string;
  priority : Llm_provider.Request_priority.t option;
  system_prompt : string;
  tools : Agent_sdk.Tool.t list;
  runtime_mcp_policy :
    Llm_provider.Llm_transport.runtime_mcp_policy option;
  max_idle_turns : int;
  stream_idle_timeout_s : float option;
  max_execution_time_s : float option;
  body_timeout_s : float option;
  max_tokens : int;
  max_input_tokens : int option;
  max_cost_usd : float option;
  temperature : float;
  hooks : Agent_sdk.Hooks.hooks option;
  context_reducer : Agent_sdk.Context_reducer.t option;
  guardrails : Agent_sdk.Guardrails.t option;
  event_bus : Agent_sdk.Event_bus.t option;
  checkpoint_dir : string option;
  session_id : string option;
  description : string option;
  initial_messages : Agent_sdk.Types.message list;
  raw_trace : Agent_sdk.Raw_trace.t option;
  trace_link : (string * string) option;
  enable_thinking : bool option;
  preserve_thinking : bool option;
  transport : Masc_grpc_transport.t;
  allowed_paths : string list;
  checkpoint_sidecar : Yojson.Safe.t option;
  cache_system_prompt : bool;
  yield_on_tool : bool;
  compact_ratio : float option;
  oas_auto_context_overflow_retry : bool;
  context_injector : Agent_sdk.Hooks.context_injector option;
  context : Agent_sdk.Context.t option;
  approval : Agent_sdk.Hooks.approval_callback option;
  exit_condition : (int -> bool) option;
  exit_condition_result : (int -> stop_reason * string option) option;
  summarizer : (Agent_sdk.Types.message list -> string) option;
      (** Custom summarizer for OAS [Budget_strategy.reduce_for_budget]
          Emergency-phase compaction. Defaults to OAS's extractive
          default. Keeper workers inject [Keeper_summarizer.keeper_summarizer]
          to scrub [STATE] blocks before the 100-char truncation. *)
  execution_idle_timeout_s : float option;
  thinking_budget : int option;
  min_p : float option;
  on_run_complete : (bool -> unit) option;
  disclosure_level : Agent_sdk.Tool.disclosure_level option;
  disclosure_resolver
      : (Agent_sdk.Types.tool_result list -> Agent_sdk.Tool.disclosure_level option) option;
  tool_selector : Agent_sdk.Tool_selector.strategy option;
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
    { event = "completed"; status = "continuation_checkpoint"; error = None }
  | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.AgentExecutionTimeout _)) ->
    { event = "failed"; status = "agent_execution_timeout"; error = None }
  | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.AgentExecutionIdleTimeout _)) ->
    { event = "failed"; status = "agent_idle_timeout"; error = None }
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

let provider_supports_runtime_mcp_lane =
  Runtime_transport.provider_supports_runtime_mcp_lane

let dedupe_preserve_order =
  Runtime_transport.dedupe_preserve_order

let public_mcp_tool_names_of_oas_tools =
  Runtime_transport.public_mcp_tool_names_of_oas_tools

let public_mcp_tool_requires_bound_actor =
  Runtime_transport.public_mcp_tool_requires_bound_actor

let runtime_mcp_tool_requires_bound_actor =
  Runtime_transport.runtime_mcp_tool_requires_bound_actor

let runtime_mcp_policy_with_masc_agent_name =
  Runtime_transport.runtime_mcp_policy_with_masc_agent_name

let cli_tool_a_can_auth_keeper_bound_runtime_mcp =
  Runtime_transport.cli_tool_a_can_auth_keeper_bound_runtime_mcp

let runtime_mcp_policy_for_provider =
  Runtime_transport.runtime_mcp_policy_for_provider

let public_mcp_tools_of_oas_tools =
  Runtime_transport.public_mcp_tools_of_oas_tools

let tool_names_are_public_mcp =
  Runtime_transport.tool_names_are_public_mcp

let public_mcp_runtime_policy_of_tool_names =
  Runtime_transport.public_mcp_runtime_policy_of_tool_names

let runtime_mcp_policy_of_tool_names =
  Runtime_transport.runtime_mcp_policy_of_tool_names

let provider_label =
  Runtime_transport.provider_label

let resolve_tool_lane_for_oas_tools =
  Runtime_transport.resolve_tool_lane_for_oas_tools

let request_runtime_fields_on_base_config
    ~(base : Llm_provider.Provider_config.t)
    (req_config : Llm_provider.Provider_config.t)
  =
  { base with
    max_tokens = req_config.max_tokens;
    temperature = req_config.temperature;
    top_p = req_config.top_p;
    top_k = req_config.top_k;
    min_p = req_config.min_p;
    system_prompt = req_config.system_prompt;
    enable_thinking = req_config.enable_thinking;
    preserve_thinking = req_config.preserve_thinking;
    thinking_budget = req_config.thinking_budget;
    clear_thinking = req_config.clear_thinking;
    tool_stream = req_config.tool_stream;
    tool_choice = req_config.tool_choice;
    disable_parallel_tool_use = req_config.disable_parallel_tool_use;
    response_format = req_config.response_format;
    output_schema = req_config.output_schema;
    cache_system_prompt = req_config.cache_system_prompt;
    supports_tool_choice_override =
      (match req_config.supports_tool_choice_override with
       | Some _ as override -> override
       | None -> base.supports_tool_choice_override);
    seed = req_config.seed;
  }

let provider_resource_slot_transport
    ~(kind : Fd_accountant.kind)
    (transport : Llm_provider.Llm_transport.t)
  : Llm_provider.Llm_transport.t =
  { complete_sync =
      (fun req ->
        Fd_accountant.with_slot ~kind (fun () ->
          transport.complete_sync req));
    complete_stream =
      (fun ?on_telemetry ~on_event req ->
        Fd_accountant.with_slot ~kind (fun () ->
          transport.complete_stream ?on_telemetry ~on_event req));
  }

let provider_http_slot_transport transport =
  provider_resource_slot_transport ~kind:Provider_http transport

let provider_config_preserving_http_transport
    ~sw
    ~net
    ?clock
    ?stream_idle_timeout_s
    ?body_timeout_s
    ~(provider_cfg : Llm_provider.Provider_config.t)
    ()
  : Llm_provider.Llm_transport.t =
  let http_transport =
    Llm_provider.Complete.make_http_transport
      ?clock
      ?stream_idle_timeout_s
      ?body_timeout_s
      ~sw
      ~net
      ()
  in
  let patch_request (req : Llm_provider.Llm_transport.completion_request) =
    { req with
      config =
        request_runtime_fields_on_base_config ~base:provider_cfg req.config;
    }
  in
  provider_http_slot_transport
    { complete_sync =
      (fun req ->
        (* RFC-0095 Phase 0 diagnostic trace — verify which transport path is invoked
           per turn for each provider. Removed at Phase 0 closeout. *)
        Log.Misc.debug
          "rfc0095-trace: runtime_runner http_transport.complete_sync invoked";
        http_transport.complete_sync (patch_request req));
      complete_stream =
      (fun ?on_telemetry ~on_event req ->
        (* RFC-0095 Phase 0 diagnostic trace — verify which transport path is invoked
           per turn for each provider. Removed at Phase 0 closeout. *)
        Log.Misc.debug
          "rfc0095-trace: runtime_runner http_transport.complete_stream invoked";
        http_transport.complete_stream ?on_telemetry ~on_event
          (patch_request req));
    }

let transport_for_provider ~sw ~net ?clock ?stream_idle_timeout_s ?body_timeout_s ~provider_cfg () =
  (* CLI subprocess transport removed (2026-05-31); every provider dispatches
     over HTTP. Runtime MCP policy is applied via the tool-lane resolver and
     per-request patching, not at transport construction, so it is no longer
     threaded here. *)
  Ok (Some (provider_config_preserving_http_transport ~sw ~net ?clock ?stream_idle_timeout_s ?body_timeout_s ~provider_cfg ()))

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
  : float Eio.Time.clock_ty Eio.Resource.t option =
  match process_clock, ctx_clock with
  | Ok c, _ -> Some c
  | Error _, (Some _ as c) -> c
  | Error e, None ->
    (match stream_idle_timeout_s with
     | Some idle ->
       failwith
         (Printf.sprintf
            "runtime_agent: stream_idle_timeout_s configured (%.1fs) but no \
             clock resolvable (%s); refusing to run with a silently disarmed \
             stream idle timeout"
            idle
            e)
     | None -> None)
;;

let resolve_clock_for_idle ~(stream_idle_timeout_s : float option) =
  decide_clock_for_idle
    ~stream_idle_timeout_s
    ~process_clock:(Process_eio.get_clock ())
    ~ctx_clock:(Eio_context.get_clock_opt ())
;;

module For_testing = struct
  let request_runtime_fields_on_base_config =
    request_runtime_fields_on_base_config

  let provider_http_slot_transport = provider_http_slot_transport
  let runtime_id_of_config = runtime_id_of_config
  let runtime_observation_for_completed_config =
    runtime_observation_for_completed_config
  let runtime_observation_for_terminal_config =
    runtime_observation_for_terminal_config
  let decide_clock_for_idle = decide_clock_for_idle
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
    ("max_tokens", `Int config.max_tokens);

  ]
  @ nonempty_string "base_url" provider_cfg.base_url
  @ nonempty_string "request_path" provider_cfg.request_path
  @ endpoint

(* ================================================================ *)
(* Internal: checkpoint persistence                                  *)
(* ================================================================ *)

let persist_checkpoint =
  Runtime_oas_checkpoint.persist_checkpoint

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
  let clock =
    resolve_clock_for_idle ~stream_idle_timeout_s:config.stream_idle_timeout_s
  in
  match
    transport_for_provider
      ~sw
      ~net
      ?clock
      ?stream_idle_timeout_s:config.stream_idle_timeout_s
      ?body_timeout_s:config.body_timeout_s
      ~provider_cfg:config.provider_cfg
      ()
  with
  | Error _ as e -> e
  | Ok transport ->
      let builder =
        Runtime_agent_context.builder_without_approval ~net ~config ?transport ()
      in
      let builder =
        match config.approval with
        | Some cb -> Agent_sdk.Builder.with_approval cb builder
        | None -> builder
      in
      Agent_sdk.Builder.build_safe builder

(* ================================================================ *)
(* Idle-detail enrichment                                           *)
(* ================================================================ *)

(** Enrich an [Agent_sdk.Error.to_string] detail with the name of the most
    recently called tool when the error is an "Idle detected" failure.
    For all other error strings the input is returned unchanged.

    Exposed at module level so it can be unit-tested independently of
    the network-bound [run] function. *)
let enrich_idle_detail =
  Runtime_oas_checkpoint.enrich_idle_detail

let run_duration_ms_since started_at =
  Float.max 0.0 ((Unix.gettimeofday () -. started_at) *. 1000.0)

let dashboard_status_of_stop_reason = function
  | Completed -> Dashboard_oas_bridge.Success
  | TurnBudgetExhausted _ -> Dashboard_oas_bridge.Success
  | MutationBoundaryReached _ ->
      Dashboard_oas_bridge.Cancelled { reason = "mutation_boundary_reached" }

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
    temperature, tools, hooks, guardrails, etc.

    [max_cost_usd] is adjusted to account for cumulative values in
    the checkpoint.

    @boundary-contract
    - MASC owns: per-turn config selection (model, temperature, tools,
      system_prompt), per-turn budget allocation, checkpoint field patching
      to align MASC intent with OAS resume semantics.
    - OAS owns: cumulative token/cost accounting, turn_count tracking,
      Agent.resume state restoration, loop guard enforcement.
    - Neither may: MASC must not set [max_total_tokens] (OAS SSOT for
      cumulative budgets); OAS must not override MASC model/temperature
      selection after resume. *)
let resume_from_checkpoint
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ~(checkpoint : Agent_sdk.Checkpoint.t)
  : (Agent_sdk.Agent.t, Agent_sdk.Error.sdk_error) result =
  let clock =
    resolve_clock_for_idle ~stream_idle_timeout_s:config.stream_idle_timeout_s
  in
  match
    transport_for_provider
      ~sw
      ~net
      ?clock
      ?stream_idle_timeout_s:config.stream_idle_timeout_s
      ?body_timeout_s:config.body_timeout_s
      ~provider_cfg:config.provider_cfg
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
           ~options ~config:prepared_resume.agent_config
           ~auto_context_overflow_retry:config.oas_auto_context_overflow_retry
           ())

(* ================================================================ *)
(* Run                                                               *)
(* ================================================================ *)

let run
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ?oas_checkpoint
    ?(on_event : (Agent_sdk.Types.sse_event -> unit) option)
    ?(on_yield : (unit -> unit) option)
    ?(on_resume : (unit -> unit) option)
    ?(agent_ref : Agent_sdk.Agent.t option ref option)
    (goal : string)
  : (run_result, Agent_sdk.Error.sdk_error) result =
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
  Option.iter (fun bus ->
    publish_lifecycle bus ~name:config.name ~event:"build" ~detail:goal
      ~attrs:(provider_lifecycle_attrs config)
      ()
  ) config.event_bus;
  let agent_result = match oas_checkpoint with
    | Some checkpoint ->
      (try resume_from_checkpoint ~sw ~net ~config ~checkpoint
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn "oas_worker %s: resume_from_checkpoint failed (%s), falling back to build"
           config.name (Printexc.to_string exn);
         build ~sw ~net ~config)
    | None -> build ~sw ~net ~config
  in
  match agent_result with
  | Error e ->
    Option.iter (fun bus ->
      publish_lifecycle bus ~name:config.name ~event:"build_error"
        ~detail:(Agent_sdk.Error.to_string e)
        ~error:(Agent_sdk.Error.to_string e)
        ~status:"build_error"
        ~session_id
        ~attrs:(provider_lifecycle_attrs config)
        ()
    ) config.event_bus;
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
          | Some cb -> Agent_sdk.Agent.run_stream ~sw ?clock ?on_yield ?on_resume ~on_event:cb agent goal
          | None -> Agent_sdk.Agent.run ~sw ?clock ?on_yield ?on_resume agent goal)
    in
    let run_total_duration_ms = run_duration_ms_since run_started_at in
    let checkpoint =
      let ckpt =
        build_checkpoint ~session_id
          ?checkpoint_sidecar:config.checkpoint_sidecar agent
      in
      (match config.checkpoint_dir with
       | Some dir ->
         (match persist_checkpoint ~dir ~session_id ckpt with
          | Ok () -> ()
          | Error err ->
            Log.Misc.error "oas_worker: %s" err)
       | None -> ());
      Some ckpt
    in
    Option.iter (fun bus ->
      let lifecycle = worker_lifecycle_classification_of_result result in
      publish_lifecycle bus ~name:config.name ~event:lifecycle.event
        ~detail:(Printf.sprintf "session=%s" session_id)
        ?error:lifecycle.error
        ~session_id
        ~status:lifecycle.status
        ~attrs:(provider_lifecycle_attrs config)
        ()
    ) config.event_bus;
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
      let partial_response =
        partial_response_of_stop
          ~session_id
          (* Display text only.  Checkpoint classification flows through
             [stop_reason] → [Keeper_turn_outcome] (RFC-0232 P2); no
             consumer may sniff this string. *)
          ~text:
            "Continuation checkpoint saved; keeper remains scheduled for the \
             next cycle."
      in
      record_dashboard_oas_response ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:(dashboard_status_of_stop_reason
                   (TurnBudgetExhausted { turns_used = r.turns; limit = r.limit }))
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
          stop_reason = TurnBudgetExhausted { turns_used = r.turns; limit = r.limit };
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
           (Agent_sdk.Error.AgentExecutionTimeout r as agent_err)) ->
      let partial_response =
        partial_response_of_stop
          ~session_id
          ~text:
            (Printf.sprintf
               "[agent execution timeout: elapsed=%.1fs timeout=%.1fs turns=%d]"
               r.elapsed_sec
               r.timeout_sec
               r.turn_count)
      in
      record_dashboard_oas_response
        ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:Dashboard_oas_bridge.Timeout
        partial_response;
      close_agent_for_cleanup ~propagate_cancel:false ~config agent;
      Error (Agent_sdk.Error.Agent agent_err)
    | Error
        (Agent_sdk.Error.Agent
           (Agent_sdk.Error.AgentExecutionIdleTimeout r as agent_err)) ->
      (* No-progress (idle) timeout. Keeper runtime config may set
         [execution_idle_timeout_s] to catch Agent-level stalls while leaving
         healthy streaming runs alive. Treat it like a timeout for the
         dashboard, preserving idle-specific fields/text. *)
      let partial_response =
        partial_response_of_stop
          ~session_id
          ~text:
            (Printf.sprintf
               "[agent idle timeout: idle=%.1fs timeout=%.1fs turns=%d]"
               r.idle_sec
               r.idle_timeout_sec
               r.turn_count)
      in
      record_dashboard_oas_response
        ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:Dashboard_oas_bridge.Timeout
        partial_response;
      close_agent_for_cleanup ~propagate_cancel:false ~config agent;
      Error (Agent_sdk.Error.Agent agent_err)
    | Error err ->
      let detail = Agent_sdk.Error.to_string err in
      let detail =
        enrich_idle_detail detail (Agent_sdk.Agent.state agent).messages
      in
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
    (* Keep the typed internal-error envelope, but construct it locally so
       Runtime_agent does not depend on Keeper_meta_contract. *)
    let typed_internal_error =
      "[masc_oas_error] "
      ^ Yojson.Safe.to_string
          (`Assoc
            [ "kind", `String "internal_unhandled_exception"
            ; "site", `String "runtime_runner.execute"
            ; "exn_repr", `String (Printexc.to_string exn)
            ])
    in
    Error (Agent_sdk.Error.Internal typed_internal_error))

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
  match
    public_mcp_runtime_policy_of_tool_names
      (List.map (fun (td : Masc_domain.tool_schema) -> td.name) masc_tools)
  with
  | Some runtime_mcp_policy
    when Provider_tool_support.provider_supports_runtime_mcp_policy
           config.provider_cfg runtime_mcp_policy ->
      let config = { config with runtime_mcp_policy = Some runtime_mcp_policy } in
      run ~sw ~net ~config ?on_event ?on_yield ?on_resume goal
  | _ when masc_tools = [] ->
      run ~sw ~net ~config ?on_event ?on_yield ?on_resume goal
  | _ when provider_supports_inline_tools config.provider_cfg ->
      let oas_tools =
        List.map
          (fun (td : Masc_domain.tool_schema) ->
            (!oas_tool_of_masc_hook)
              ~name:td.name
              ~description:td.description
              ~input_schema:td.input_schema
              (fun input -> dispatch ~name:td.name ~args:input))
          masc_tools
      in
      let config = { config with tools = oas_tools @ config.tools } in
      run ~sw ~net ~config ?on_event ?on_yield ?on_resume goal
  | _ -> run ~sw ~net ~config ?on_event ?on_yield ?on_resume goal
