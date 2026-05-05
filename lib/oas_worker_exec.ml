(** Oas_worker_exec — Config, build, and run for OAS agent execution.

    Contains the [config] type, [build], [run], and [run_with_masc_tools]
    functions. All model-selection and cascade logic lives in
    {!Oas_worker_cascade} and {!Oas_worker_named}.

    @since God file decomposition — extracted from oas_worker.ml *)

(* ================================================================ *)
(* Configuration                                                     *)
(* ================================================================ *)

type stop_reason =
  Oas_worker_exec_agent.stop_reason =
  | Completed
  | TurnBudgetExhausted of { turns_used : int; limit : int }
  | MutationBoundaryReached of { turns_used : int; tool_name : string option }

type cli_transport_overrides =
  Oas_worker_exec_transport.cli_transport_overrides = {
  cwd : string option;
  claude_mcp_config : string option;
  claude_allowed_tools : string list option;
  claude_permission_mode : string option;
  claude_max_turns : int option;
  gemini_yolo : bool option;
}

type config =
  Oas_worker_exec_agent.config = {
  name : string;
  provider_cfg : Llm_provider.Provider_config.t;
  provider : Agent_sdk.Provider.config;
  model_id : string;
  priority : Llm_provider.Request_priority.t option;
  system_prompt : string;
  tools : Agent_sdk.Tool.t list;
  runtime_mcp_policy :
    Llm_provider.Llm_transport.runtime_mcp_policy option;
  max_turns : int;
  max_idle_turns : int;
  stream_idle_timeout_s : float option;
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
  memory : Agent_sdk.Memory.t option;
  initial_messages : Agent_sdk.Types.message list;
  raw_trace : Agent_sdk.Raw_trace.t option;
  tool_retry_policy : Agent_sdk.Tool_retry_policy.t option;
  required_tool_satisfaction :
    Agent_sdk.Completion_contract.required_tool_satisfaction;
  contract : Agent_sdk.Risk_contract.t option;
  enable_thinking : bool option;
  transport : Masc_grpc_transport.t;
  allowed_paths : string list;
  checkpoint_sidecar : Yojson.Safe.t option;
  cache_system_prompt : bool;
  yield_on_tool : bool;
  compact_ratio : float option;
  context_injector : Agent_sdk.Hooks.context_injector option;
  context : Agent_sdk.Context.t option;
  slot_id : int option;
  approval : Agent_sdk.Hooks.approval_callback option;
  exit_condition : (int -> bool) option;
  exit_condition_result : (int -> stop_reason * string option) option;
  summarizer : (Agent_sdk.Types.message list -> string) option;
  cli_transport_overrides : cli_transport_overrides option;
      (** Custom summarizer for OAS [Budget_strategy.reduce_for_budget]
          Emergency-phase compaction. Defaults to OAS's extractive
          default. Keeper workers inject [Keeper_summarizer.keeper_summarizer]
          to scrub [STATE] blocks before the 100-char truncation. *)
}

let default_config = Oas_worker_exec_agent.default_config

type run_result = {
  response : Agent_sdk.Types.api_response;
  checkpoint : Agent_sdk.Checkpoint.t option;
  session_id : string;
  turns : int;
  trace_ref : Agent_sdk.Raw_trace.run_ref option;
  run_validation : Agent_sdk.Raw_trace.run_validation option;
  proof : Agent_sdk.Cdal_proof.t option;
  cascade_observation : Oas_worker_cascade.cascade_observation option;
  stop_reason : stop_reason;
}

let lowercase_enum_case_name raw =
  let raw =
    match String.rindex_opt raw '.' with
    | Some idx when idx + 1 < String.length raw ->
        String.sub raw (idx + 1) (String.length raw - idx - 1)
    | _ -> raw
  in
  String.lowercase_ascii raw

let proof_result_status_to_string status =
  Agent_sdk.Cdal_proof.show_result_status status |> lowercase_enum_case_name

(* ================================================================ *)
(* Internal: resolve provider                                        *)
(* ================================================================ *)

(** Resolve a model label string to an OAS Provider.config.
    Uses MASC [Cascade_config.parse_model_string] (with Provider_registry as SSOT).
    Explicit model-label execution must never silently substitute a
    discovery-only model. Callers are expected to validate labels
    before reaching this helper. *)
type label_resolution_error =
  Oas_worker_exec_transport.label_resolution_error =
  | Invalid_model_label of string

let label_resolution_error_to_string =
  Oas_worker_exec_transport.label_resolution_error_to_string

let label_resolution_error_to_sdk_error =
  Oas_worker_exec_transport.label_resolution_error_to_sdk_error

let resolve_provider_config_of_label =
  Oas_worker_exec_transport.resolve_provider_config_of_label

let invalid_runtime_config =
  Oas_worker_exec_transport.invalid_runtime_config

let cli_model_override =
  Oas_worker_exec_transport.cli_model_override

let provider_caps_of_config =
  Oas_worker_exec_transport.provider_caps_of_config

let kimi_mcp_config_json_of_policy =
  Oas_worker_exec_transport.kimi_mcp_config_json_of_policy

let kimi_cli_model_for_provider =
  Oas_worker_exec_transport.kimi_cli_model_for_provider

let kimi_cli_config_json_for_provider =
  Oas_worker_exec_transport.kimi_cli_config_json_for_provider

let provider_supports_inline_tools =
  Oas_worker_exec_transport.provider_supports_inline_tools

let provider_supports_runtime_mcp_lane =
  Oas_worker_exec_transport.provider_supports_runtime_mcp_lane

let dedupe_preserve_order =
  Oas_worker_exec_transport.dedupe_preserve_order

let public_mcp_tool_names_of_oas_tools =
  Oas_worker_exec_transport.public_mcp_tool_names_of_oas_tools

let public_mcp_tool_requires_bound_actor =
  Oas_worker_exec_transport.public_mcp_tool_requires_bound_actor

let runtime_mcp_tool_requires_bound_actor =
  Oas_worker_exec_transport.runtime_mcp_tool_requires_bound_actor

let runtime_mcp_policy_with_masc_agent_name =
  Oas_worker_exec_transport.runtime_mcp_policy_with_masc_agent_name

let runtime_mcp_policy_for_provider =
  Oas_worker_exec_transport.runtime_mcp_policy_for_provider

let kimi_cli_runtime_mcp_jsons =
  Oas_worker_exec_transport.kimi_cli_runtime_mcp_jsons

let public_mcp_tools_of_oas_tools =
  Oas_worker_exec_transport.public_mcp_tools_of_oas_tools

let tool_names_are_public_mcp =
  Oas_worker_exec_transport.tool_names_are_public_mcp

let public_mcp_runtime_policy_of_tool_names =
  Oas_worker_exec_transport.public_mcp_runtime_policy_of_tool_names

let runtime_mcp_policy_of_tool_names =
  Oas_worker_exec_transport.runtime_mcp_policy_of_tool_names

let provider_label =
  Oas_worker_exec_transport.provider_label

let claude_code_max_turns_hard_cap =
  Oas_worker_exec_transport.claude_code_max_turns_hard_cap

let provider_effective_max_turns =
  Oas_worker_exec_transport.provider_effective_max_turns

let resolve_tool_lane_for_oas_tools =
  Oas_worker_exec_transport.resolve_tool_lane_for_oas_tools

let make_per_call_switch_transport =
  Oas_worker_exec_transport.make_per_call_switch_transport

module Kimi_cli_transport_local = Oas_worker_exec_transport.Kimi_cli_transport_local

let non_http_transport_of_provider =
  Oas_worker_exec_transport.non_http_transport_of_provider

(* ================================================================ *)
(* Internal: event publishing                                        *)
(* ================================================================ *)

let publish_lifecycle =
  Oas_worker_exec_checkpoint.publish_lifecycle

(* ================================================================ *)
(* Internal: checkpoint persistence                                  *)
(* ================================================================ *)

let persist_checkpoint =
  Oas_worker_exec_checkpoint.persist_checkpoint

let build_checkpoint =
  Oas_worker_exec_checkpoint.build_checkpoint

let partial_response_of_stop =
  Oas_worker_exec_checkpoint.partial_response_of_stop

(* ================================================================ *)
(* Build                                                             *)
(* ================================================================ *)

let build
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
  : (Agent_sdk.Agent.t, Agent_sdk.Error.sdk_error) result =
  match
    non_http_transport_of_provider ~sw ~provider_cfg:config.provider_cfg
      ?runtime_mcp_policy:config.runtime_mcp_policy
      ?cli_transport_overrides:config.cli_transport_overrides
      ()
  with
  | Error _ as e -> e
  | Ok transport ->
      let builder =
        Oas_worker_exec_agent.builder_without_approval ~net ~config ?transport ()
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
  Oas_worker_exec_checkpoint.enrich_idle_detail

let run_duration_ms_since started_at =
  Float.max 0.0 ((Unix.gettimeofday () -. started_at) *. 1000.0)

let dashboard_status_of_stop_reason = function
  | Completed -> Dashboard_oas_bridge.Success
  | TurnBudgetExhausted _ -> Dashboard_oas_bridge.Timeout
  | MutationBoundaryReached _ ->
      Dashboard_oas_bridge.Cancelled { reason = "mutation_boundary_reached" }

let record_dashboard_oas_response ~config ~total_duration_ms ?serialization_ms
    ~status (response : Agent_sdk.Types.api_response) =
  try
    let provider_id = Provider_adapter.provider_label_of_config config.provider_cfg in
    let model_id =
      let response_model = String.trim response.model in
      if response_model = "" then config.model_id else response_model
    in
    Dashboard_oas_bridge.record_response ~provider_id ~model_id
      ~total_duration_ms ?serialization_ms ~status response
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Log.Misc.warn
        "oas_worker %s: dashboard_oas_bridge record failed: %s"
        config.name (Printexc.to_string exn)

(* ================================================================ *)
(* Resume from checkpoint                                            *)
(* ================================================================ *)

(** Build an Agent.t from a checkpoint via [Agent.resume], overriding
    per-turn config values from the MASC config.

    The checkpoint provides: messages, turn_count, usage_stats.
    The MASC config provides: provider, model_id, system_prompt,
    max_turns, temperature, tools, hooks, guardrails, etc.

    [max_turns] and [max_cost_usd] are adjusted to account for
    cumulative values in the checkpoint — the keeper's per-call budget
    is added on top of the checkpoint's accumulated state.

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
  match
    non_http_transport_of_provider ~sw ~provider_cfg:config.provider_cfg
      ?runtime_mcp_policy:config.runtime_mcp_policy
      ?cli_transport_overrides:config.cli_transport_overrides
      ()
  with
  | Error _ as e -> e
  | Ok transport ->
      let prepared_resume =
        Oas_worker_exec_agent.prepare_resume ~config ~checkpoint
      in
      Log.Misc.info
        "oas_worker %s: resume checkpoint_turn_count=%d per_call_turn_budget=%d effective_max_turns=%d"
        config.name checkpoint.turn_count config.max_turns
        prepared_resume.agent_config.max_turns;
      let options = { prepared_resume.options with transport } in
      Ok
        (Agent_sdk.Agent.resume ~net ~checkpoint:prepared_resume.patched_checkpoint
           ~tools:config.tools ?context:config.context
           ~options ~config:prepared_resume.agent_config ())

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
    ?(proof_ref : Agent_sdk.Cdal_proof.t option ref option)
    ?(contract : Agent_sdk.Risk_contract.t option)
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
        ()
    ) config.event_bus;
    Error e
  | Ok agent ->
  (match agent_ref with Some r -> r := Some agent | None -> ());
  let effective_contract = match contract with Some c -> Some c | None -> config.contract in
  let run_started_at = Unix.gettimeofday () in
  (try
    let result, proof = match effective_contract with
      | Some c ->
        let cr = Agent_sdk.Contract_runner.run ~sw ~contract:c agent goal in
        (cr.response, Some cr.proof)
      | None ->
        let r = match on_event with
          | Some cb -> Agent_sdk.Agent.run_stream ~sw ?on_yield ?on_resume ~on_event:cb agent goal
          | None -> Agent_sdk.Agent.run ~sw ?on_yield ?on_resume agent goal
        in
        (r, None)
    in
    let run_total_duration_ms = run_duration_ms_since run_started_at in
    (match proof_ref with Some ref_ -> ref_ := proof | None -> ());
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
      let status = match result with Ok _ -> "completed" | Error _ -> "failed" in
      let error =
        match result with
        | Ok _ -> None
        | Error e -> Some (Agent_sdk.Error.to_string e)
      in
      publish_lifecycle bus ~name:config.name ~event:status
        ~detail:(Printf.sprintf "session=%s" session_id)
        ?error
        ~session_id
        ~status
        ()
    ) config.event_bus;
    let turns = (Agent_sdk.Agent.state agent).turn_count in
    let trace_ref = Agent_sdk.Agent.last_raw_trace_run agent in
    Agent_sdk.Agent.close agent;
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
      record_dashboard_oas_response ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:Dashboard_oas_bridge.Success response;
      Ok
        {
          response;
          checkpoint;
          session_id;
          turns;
          trace_ref;
          run_validation;
          proof;
          cascade_observation = None;
          stop_reason = Completed;
        }
    | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.MaxTurnsExceeded r)) ->
      let partial_response =
        partial_response_of_stop
          ~session_id
          ~model_id:config.model_id
          ~text:(Printf.sprintf
            "[turn budget exhausted: %d/%d turns used]" r.turns r.limit)
      in
      record_dashboard_oas_response ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:Dashboard_oas_bridge.Timeout partial_response;
      Ok
        {
          response = partial_response;
          checkpoint;
          session_id;
          turns;
          trace_ref;
          run_validation;
          proof;
          cascade_observation = None;
          stop_reason = TurnBudgetExhausted { turns_used = r.turns; limit = r.limit };
        }
    | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.ExitConditionMet r)) -> (
      match config.exit_condition_result with
      | Some render ->
        let stop_reason, response_text_opt = render r.turn in
        let response_text =
          match response_text_opt with
          | Some text when String.trim text <> "" -> text
          | _ -> Printf.sprintf "[exit condition met at turn %d]" r.turn
        in
        let partial_response =
          partial_response_of_stop
            ~session_id
            ~model_id:config.model_id
            ~text:response_text
        in
        record_dashboard_oas_response ~config
          ~total_duration_ms:run_total_duration_ms
          ~status:(dashboard_status_of_stop_reason stop_reason)
          partial_response;
        Ok
          {
            response = partial_response;
            checkpoint;
            session_id;
            turns;
            trace_ref;
            run_validation;
            proof;
            cascade_observation = None;
            stop_reason;
          }
      | None ->
        Error (Agent_sdk.Error.Agent (Agent_sdk.Error.ExitConditionMet r)))
    | Error err ->
      let detail = Agent_sdk.Error.to_string err in
      let detail =
        enrich_idle_detail detail (Agent_sdk.Agent.state agent).messages
      in
      let error_response =
        partial_response_of_stop ~session_id ~model_id:config.model_id
          ~text:detail
      in
      record_dashboard_oas_response ~config
        ~total_duration_ms:run_total_duration_ms
        ~status:(Dashboard_oas_bridge.Error { transient = false })
        error_response;
      (* Demoted from WARN to DEBUG (task-239): this fires once per tier,
         but a cascade caller (Oas_worker_named.run_named) retries on the
         next provider.  Emitting WARN/ERROR here creates noise on
         recovered cascades.  The cascade layer logs [cascade-fallback] at
         INFO when it retries and emits ERROR only on full exhaustion. *)
      (match proof with
       | Some p ->
         Log.Misc.debug "oas_worker: agent errored with CDAL proof: run_id=%s status=%s error=%s"
           p.run_id
           (proof_result_status_to_string p.result_status)
           detail
       | None ->
         Log.Misc.debug "oas_worker: agent errored (no proof): %s" detail);
      Error err)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let bt = Printexc.get_backtrace () in
    (try Agent_sdk.Agent.close agent with close_exn ->
      Log.Misc.warn "agent close failed during cleanup: %s" (Printexc.to_string close_exn));
    let detail =
      Printf.sprintf "execution exception: %s" (Printexc.to_string exn)
    in
    let error_response =
      partial_response_of_stop ~session_id ~model_id:config.model_id
        ~text:detail
    in
    record_dashboard_oas_response ~config
      ~total_duration_ms:(run_duration_ms_since run_started_at)
      ~status:(Dashboard_oas_bridge.Error { transient = false })
      error_response;
    Log.Misc.error "oas_worker %s: execution exception: %s\nBacktrace: %s"
      config.name (Printexc.to_string exn) bt;
    Error (Agent_sdk.Error.Internal (Printf.sprintf "execution exception: %s" (Printexc.to_string exn))))

(* ================================================================ *)
(* Convenience: run_with_masc_tools                                  *)
(* ================================================================ *)

let run_with_masc_tools
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?contract
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
      run ~sw ~net ~config ?on_event ?on_yield ?on_resume ?contract goal
  | _ when masc_tools = [] ->
      run ~sw ~net ~config ?on_event ?on_yield ?on_resume ?contract goal
  | _ when provider_supports_inline_tools config.provider_cfg ->
      let oas_tools =
        List.map
          (fun (td : Masc_domain.tool_schema) ->
            Tool_bridge.oas_tool_of_masc
              ~name:td.name
              ~description:td.description
              ~input_schema:td.input_schema
              (fun input -> dispatch ~name:td.name ~args:input))
          masc_tools
      in
      let config = { config with tools = oas_tools @ config.tools } in
      run ~sw ~net ~config ?on_event ?on_yield ?on_resume ?contract goal
  | _ ->
      Error
        (invalid_runtime_config "tool_support"
           (Printf.sprintf
              "%s does not support inline tools or request-scoped runtime MCP tools"
              (provider_label config.provider_cfg)))
