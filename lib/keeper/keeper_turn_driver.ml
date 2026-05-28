(** Keeper_turn_driver — MASC named-cascade and model-label execution entry points.

    Public API for running OAS agents through MASC-managed named cascade
    profiles ([run_named])
    or explicit model label ([run_model_by_label]), with optional MASC
    tool bridging variants.

    @since God file decomposition — extracted from oas_worker.ml *)

open Result.Syntax
open Cascade_name

(* Sub-module includes (God file decomposition).
   Each sub-module is self-contained; the facade re-exports everything
   so existing callers do not need qualification. *)
include Cascade_oas_runner
include Cascade_error_classify
include Cascade_attempt_fsm
include Keeper_turn_driver_helpers

include Keeper_turn_driver_provider_attempt
include Keeper_turn_driver_backpressure

let keeper_cascade_tier_admission =
  Keeper_turn_driver_admission.keeper_cascade_tier_admission

let cascade_tier_admission_policy_of_priority =
  Keeper_turn_driver_admission.cascade_tier_admission_policy_of_priority

let with_keeper_cascade_tier_admission =
  Keeper_turn_driver_admission.with_keeper_cascade_tier_admission

let cascade_tier_admission_blocked_decision =
  Keeper_turn_driver_admission.cascade_tier_admission_blocked_decision

let emit_cascade_tier_admission_signal_metric =
  Keeper_turn_driver_admission.emit_cascade_tier_admission_signal_metric

let release_client_capacity_quietly =
  Keeper_turn_driver_admission.release_client_capacity_quietly

let provider_config_identity_key =
  Keeper_turn_driver_admission.provider_config_identity_key

let runtime_candidates_of_tiered_providers =
  Keeper_turn_driver_admission.runtime_candidates_of_tiered_providers
let run_named
    ~cascade_name
    ?base_path
    ?(keeper_name = "")
    ~goal
    ?provider_filter
    ?(require_tool_choice_support = false)
    ?(require_tool_support = false)
    ?priority
    ?session_id
    ?(system_prompt = "")
    ?(tools = [])
    ?(initial_messages = [])
    ?(max_turns = 20)
    ?(max_idle_turns = 3)
    ?stream_idle_timeout_s
    ?(temperature = Llm_provider.Constants.Inference_profile.agent_default.temperature)
    ?(max_tokens = Llm_provider.Constants.Inference_profile.agent_default.max_tokens)
    ?max_input_tokens
    ?max_cost_usd
    ?wait_timeout_sec
    ?(accept = fun (_ : Agent_sdk_response.api_response) -> true)
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ?tool_retry_policy
    ?(required_tool_satisfaction =
      Agent_sdk.Completion_contract.any_tool_call_satisfies)
    ?raw_trace
    ?on_event
    ?on_yield
    ?on_resume
    ?agent_ref
    ?proof_ref
    ?contract
    ?transport
    ?cli_transport_overrides
    ?(allowed_paths = [])
    ?checkpoint_sidecar
    ?(cache_system_prompt = false)
    ?(yield_on_tool = false)
    ?compact_ratio
    ?(oas_auto_context_overflow_retry = true)
    ?checkpoint_dir
    ?context_injector
    ?context
    ?slot_id
    ?enable_thinking
    ?approval
    ?exit_condition
    ?exit_condition_result
    ?summarizer
    ?oas_checkpoint
    ?event_bus
    ?runtime_manifest_context
    ?runtime_manifest_append
    ?(runtime_manifest_required_tool_names = [])
    ?sw
    ?net
    ?per_provider_timeout_s
    ()
  : (Cascade_runner.run_result, Agent_sdk.Error.sdk_error) result =
  let cascade_engine = Keeper_cascade_engine.keeper_managed in
  match Keeper_cascade_engine.guard_keeper_hot_path cascade_engine with
  | Error msg -> Error (Agent_sdk.Error.Internal msg)
  | Ok () ->
  match require_eio ?sw ?net () with
  | Error e -> Error (eio_context_error_to_sdk_error e)
  | Ok (sw, net) ->
  let cascade_name =
    Keeper_cascade_profile.normalize_declared_name cascade_name
  in
  let error_cascade_name = Cascade_name.of_string_exn cascade_name in
  let runtime_cascade_name = Cascade_name.of_string_exn cascade_name in
  let runtime_mcp_policy = runtime_mcp_policy_for_tools ~keeper_name tools in
  (* Keeper-internal tools cannot degrade to a text-only CLI palette: the
     model would see no callable schema and emit misleading diagnostics. *)
  let require_tool_support =
    require_tool_support
    || keeper_internal_tools_require_materialized_runtime_surface
         ~keeper_name tools
  in
  let named_resolution =
    Keeper_turn_driver_named_resolution.resolve
      ~sw
      ~net
      ?provider_filter
      ~cascade_name
      ~runtime_cascade_name
      ()
  in
  (match
     ( named_resolution.configured_labels_result,
       named_resolution.candidate_cfgs_result,
       named_resolution.tiered_providers_result )
   with
   | Error detail, _, _ | _, Error detail, _ | _, _, Error detail ->
       Log.Misc.error "cascade %s: %s" cascade_name detail;
       Error (cascade_catalog_error_to_sdk_error detail)
   | Ok configured_labels, Ok candidate_cfgs, Ok tiered_providers ->
  let original_candidate_cfgs = candidate_cfgs in
  let original_candidates =
    runtime_candidates_of_tiered_providers tiered_providers original_candidate_cfgs
  in
  let required_capability_profile =
    Keeper_cascade_profile.required_capability_profile_of_cascade_name cascade_name
  in
  let tool_filtered_candidate_cfgs =
    filter_candidate_providers_for_tool_support
      ~keeper_name
      ?runtime_mcp_policy
      ~tools
      ~require_tool_choice_support
      ~require_tool_support
      ?required_capability_profile
      ?secondary_resolver:named_resolution.secondary_resolver
      ~label:cascade_name
      candidate_cfgs
  in
  let configured_label_count = List.length configured_labels in
  let original_candidate_count = List.length original_candidate_cfgs in
  let tool_filtered_candidate_count = List.length tool_filtered_candidate_cfgs in
  let tool_filtered_candidates =
    runtime_candidates_of_tiered_providers tiered_providers tool_filtered_candidate_cfgs
  in
  let required_lane_filtered_candidates, required_lane_provider_rejections =
    match runtime_manifest_required_tool_names with
    | [] -> tool_filtered_candidates, []
    | required_tool_names ->
      List.fold_right
        (fun candidate (kept, rejected) ->
           let provider_label = Cascade_runtime_candidate.provider_label candidate in
           let drop ~lane ~missing_required_tools ~materialized_tool_names =
             let reason =
               Printf.sprintf
                 "required_tool_lane_unavailable: provider=%s lane=%s \
                  missing_required_tools=[%s] materialized_tools=[%s]"
                 provider_label
                 lane
                 (String.concat ", " missing_required_tools)
                 (String.concat ", " materialized_tool_names)
             in
             Log.Keeper.warn
               "keeper:%s cascade %s: pre-dispatch skipped provider=%s reason=%s"
               keeper_name
               cascade_name
               provider_label
               reason;
             kept,
             ({ provider_label; reason }
               : Cascade_error_classify.provider_rejection)
             :: rejected
           in
           match
             Cascade_runtime_candidate.resolve_tool_lane_for_oas_tools
               ?agent_name:(Cascade_oas_runner.keeper_agent_name_opt keeper_name)
               ~tool_requirement:`Required
               ~tools
               candidate
           with
           | Error err ->
             drop
               ~lane:"unresolved"
               ~missing_required_tools:required_tool_names
               ~materialized_tool_names:[ "error=" ^ Agent_sdk.Error.to_string err ]
           | Ok (effective_tools, runtime_mcp_policy) ->
             let runtime_mcp_policy =
               match runtime_mcp_policy, String.trim keeper_name with
               | Some policy, keeper_name when keeper_name <> "" ->
                 Cascade_runtime_candidate.runtime_mcp_policy_for_agent
                   ~agent_name:(Keeper_identity.keeper_agent_name keeper_name)
                   candidate
                   (Some policy)
               | _ -> runtime_mcp_policy
             in
             let materialized_tool_names =
               materialized_tool_names_after_lane ~effective_tools ~runtime_mcp_policy
             in
             let missing_required_tools =
               missing_required_tool_names_after_lane_by_name
                 ~required_tool_names
                 ~materialized_tool_names
             in
             if missing_required_tools = []
             then candidate :: kept, rejected
             else
               drop
                 ~lane:
                   (resolved_tool_lane_label ~effective_tools ~runtime_mcp_policy)
                 ~missing_required_tools
                 ~materialized_tool_names)
        tool_filtered_candidates
        ([], [])
  in
  let health_filtered_candidates =
    required_lane_filtered_candidates
    |> List.filter
         (fun candidate ->
            match Cascade_runtime_candidate.first_health_cooldown candidate with
            | None -> true
            | Some (_provider_health_key, msg) ->
                Log.Misc.debug
                  "cascade %s: prefilter skipped %s (provider_key=%s cooldown: %s)"
                  cascade_name runtime_candidate_label runtime_candidate_label msg;
                false)
  in
  let health_filtered_candidate_count = List.length health_filtered_candidates in
  let required_lane_filtered_candidate_count =
    List.length required_lane_filtered_candidates
  in
  let dispatch_seed_candidates, health_cooldown_fail_open =
    fail_open_health_filtered_candidates
      ~tool_filtered_candidates:required_lane_filtered_candidates
      ~health_filtered_candidates
  in
  let local_endpoint_health =
    match Cascade_runtime_candidate.local_runtime_urls dispatch_seed_candidates with
    | [] -> []
    | endpoints ->
      Llm_provider.Discovery.refresh_and_sync ~sw ~net ~endpoints
      |> List.map (fun (status : Llm_provider.Discovery.endpoint_status) ->
             status.url, status.healthy)
  in
  let local_prefiltered_candidates, unhealthy_local_endpoints =
    Cascade_runtime_candidate.filter_unhealthy_local_runtime_urls
      ~endpoint_health:local_endpoint_health
      dispatch_seed_candidates
  in
  let local_prefiltered_candidate_count =
    List.length local_prefiltered_candidates
  in
  (* RFC: MASC/OAS Error-Warn Reduction Goal — 2026-05-18 §P3.
     For each unhealthy endpoint, record the preflight-skip event in
     [Cascade_preflight_state.global]. After N consecutive skips of
     the same (cascade, endpoint, reason) fingerprint we escalate to
     ERROR once and register the endpoint in the in-process disabled
     list — subsequent identical skips return [`Already_disabled] and
     are dropped to DEBUG, so the log volume drops from ~35-50/30min
     to a small fixed number of transitions.
     Routing semantics are preserved: the disabled list is advisory
     for log-level cadence; the existing
     [filter_unhealthy_local_runtime_urls] already removed these
     endpoints from [candidates]. *)
  List.iter
    (fun endpoint ->
      let outcome =
        Cascade_preflight_state.record
          Cascade_preflight_state.global
          ~tier_group:cascade_name
          ~provider:endpoint
          ~reason:Cascade_preflight_state.Health_check_failed_repeatedly
      in
      match outcome with
      | `First ->
        Log.Misc.warn
          "cascade %s: preflight skipped 1 unhealthy local endpoint(s) before \
           provider dispatch: [%s] (reason=%s, first occurrence)"
          cascade_name
          endpoint
          (Cascade_preflight_state.reason_slug
             Cascade_preflight_state.Health_check_failed_repeatedly)
      | `Repeated n ->
        Log.Misc.warn
          "cascade %s: preflight skipped 1 unhealthy local endpoint(s) before \
           provider dispatch: [%s] (reason=%s, consecutive=%d)"
          cascade_name
          endpoint
          (Cascade_preflight_state.reason_slug
             Cascade_preflight_state.Health_check_failed_repeatedly)
          n
      | `Threshold_disable n ->
        Log.Misc.error
          "cascade %s: provider [%s] disabled after %d consecutive preflight \
           unhealthy skips (reason=%s); subsequent skips silenced via \
           disabled-list. Recovery requires successful health probe."
          cascade_name
          endpoint
          n
          (Cascade_preflight_state.reason_slug
             Cascade_preflight_state.Health_check_failed_repeatedly)
      | `Already_disabled ->
        (* Drop noise: this endpoint is in the disabled list and has
           already emitted its ERROR escalation. *)
        Log.Misc.debug
          "cascade %s: preflight skipped already-disabled endpoint [%s]"
          cascade_name endpoint)
    unhealthy_local_endpoints;
  (* Recovery: for any endpoint that probed healthy this cycle, clear
     fingerprints + emit one INFO if it had been disabled. *)
  List.iter
    (fun (url, healthy) ->
      if healthy
         && Cascade_preflight_state.is_disabled
              Cascade_preflight_state.global ~provider:url
      then
        let recovered =
          Cascade_preflight_state.reset_on_health_recovery
            Cascade_preflight_state.global ~provider:url
        in
        if recovered
        then
          Log.Misc.info
            "cascade %s: provider [%s] re-enabled after successful health \
             probe; removed from disabled-list."
            cascade_name url)
    local_endpoint_health;
  let candidates = local_prefiltered_candidates in
  let optional_capacity_override ~knob resolve =
    match resolve () with
    | Ok value -> value
    | Error detail ->
      Log.Misc.warn
        "cascade %s: failed to resolve %s capacity override: %s"
        cascade_name
        knob
        detail;
      None
  in
  let register_capacity_controls candidates =
    List.iter
      Cascade_runtime_candidate.register_declared_client_capacity
      candidates;
    let capacity_keys =
      Cascade_runtime_candidate.capacity_keys candidates
      |> List.map String.trim
      |> List.filter (fun key -> not (String.equal key ""))
      |> Json_util.dedupe_keep_order
    in
    let cli_max_concurrent =
      optional_capacity_override ~knob:"cli_max_concurrent" (fun () ->
        Cascade_catalog_runtime.resolve_cli_max_concurrent
          ~sw
          ~net
          ~name:cascade_name
          ())
    in
    (match cli_max_concurrent with
     | Some max_concurrent ->
       Cascade_client_capacity.auto_register_cli_with_override
         ~capacity_keys
         ~max_concurrent
     | None ->
       Cascade_client_capacity.auto_register_cli_for_candidates ~capacity_keys);
    let http_probe_default_max_concurrent = 1 in
    let http_probe_max_concurrent =
      match
        optional_capacity_override ~knob:"ollama_max_concurrent" (fun () ->
          Cascade_catalog_runtime.resolve_ollama_max_concurrent
            ~sw
            ~net
            ~name:cascade_name
            ())
      with
      | Some max_concurrent -> max_concurrent
      | None ->
        (* DET-OK: absent or unresolved HTTP-probe capacity uses the stable
           single-flight default at the runtime boundary; configured values are
           still explicit [Some n] inputs from the cascade catalog. *)
        http_probe_default_max_concurrent
    in
    List.iter
      (Cascade_runtime_candidate.register_http_probe_capable
         ~max_concurrent:http_probe_max_concurrent)
      candidates
  in
  register_capacity_controls candidates;
  if health_cooldown_fail_open then
    Log.Misc.warn
      "cascade %s: all tool-capable candidates are in health/cooldown; \
       fail-open to surface provider result instead of no_providers_available \
       configured_label_count=%d original_candidate_count=%d \
       tool_filtered_candidate_count=%d local_prefiltered_candidate_count=%d"
      cascade_name
      configured_label_count
      original_candidate_count
      tool_filtered_candidate_count
      local_prefiltered_candidate_count;
  let _ = base_provider_attempt_provenance in
  let filter_provider_health_fail_open candidates =
    match Provider_health.active () with
    | None -> candidates
    | Some health ->
      Provider_health.filter_healthy health
        ~provider_id:Cascade_runtime_candidate.health_key
        candidates
  in
  let record_provider_health_result candidate ~success ~http_status =
    match Provider_health.active () with
    | None -> ()
    | Some health ->
      Provider_health.record_attempt_result health
        ~provider_id:(Cascade_runtime_candidate.health_key candidate)
        ~success
        ~http_status
  in
  let record_provider_health_error candidate = function
    | Provider_error.ServerError { code; _ } ->
      record_provider_health_result candidate ~success:false ~http_status:(Some code)
    | Provider_error.CapacityBackpressure _
    | Provider_error.RateLimit _
    | Provider_error.AuthError
    | Provider_error.InvalidRequest _
    | Provider_error.CliWrappedHardQuota _
    | Provider_error.CliWrappedMaxTurns _
    | Provider_error.CliWrappedResumableSession _
    | Provider_error.PermissionDenied _
    | Provider_error.ModelNotFound -> ()
  in
  match candidates with
  | [] ->
      let required_tool_names =
        required_tool_names_for_no_tool_error ~runtime_mcp_policy ~tools
      in
      let provider_rejections =
        provider_rejections_for_no_tool_error
          ~keeper_name ?runtime_mcp_policy ~tools
          ~require_tool_choice_support ~require_tool_support
          original_candidates
        @ required_lane_provider_rejections
      in
      let empty_candidate_classification =
        if
          runtime_manifest_required_tool_names <> []
          && original_candidate_count > 0
          && required_lane_filtered_candidate_count = 0
        then Tool_capability_empty
        else
          classify_empty_candidates
            ~require_tool_choice_support
            ~require_tool_support
            ~original_candidate_count
            ~tool_filtered_candidate_count
      in
      let classification_code =
        empty_candidate_classification_code empty_candidate_classification
      in
      let exhaustion_summary =
        match empty_candidate_classification with
        | Tool_capability_empty ->
          "no tool-capable providers after capability filter"
        | Provider_unavailable ->
          "providers unavailable after local preflight/health/cooldown filter"
      in
      Log.Misc.error
        "cascade %s: %s; classification=%s configured_label_count=%d \
         original_candidate_count=%d tool_filtered_candidate_count=%d \
         required_lane_filtered_candidate_count=%d local_prefiltered_candidate_count=%d \
         health_filtered_candidate_count=%d require_tool_choice_support=%b \
         require_tool_support=%b"
        cascade_name
        exhaustion_summary
        classification_code
        configured_label_count
        original_candidate_count
        tool_filtered_candidate_count
        required_lane_filtered_candidate_count
        local_prefiltered_candidate_count
        health_filtered_candidate_count
        require_tool_choice_support
        require_tool_support;
      let internal_error =
        match empty_candidate_classification with
        | Tool_capability_empty ->
          No_tool_capable_provider
            {
              cascade_name = error_cascade_name;
              configured_labels;
              required_tool_names;
              provider_rejections;
            }
        | Provider_unavailable ->
          Cascade_exhausted
            {
              cascade_name = error_cascade_name;
              reason = Keeper_types.No_providers_available;
            }
      in
      (match runtime_manifest_context, runtime_manifest_append with
       | Some manifest_ctx, Some append ->
         let provider_rejection_reasons =
           provider_rejections
           |> List.map (fun (r : Cascade_error_classify.provider_rejection) ->
                  r.reason)
           |> Json_util.dedupe_keep_order
         in
         Keeper_runtime_manifest.make_for_context manifest_ctx
           ~event:Keeper_runtime_manifest.Pre_dispatch_blocked
           ~cascade_name
           ~status:"error"
           ~decision:
             (`Assoc
               (Keeper_cascade_engine.manifest_fields cascade_engine
                @ [
                    ("reason", `String (kind_of_masc_internal_error internal_error));
                    ( "required_tool_names",
                      `List
                        (List.map
                           (fun tool_name -> `String tool_name)
                           required_tool_names) );
                    ( "empty_candidate_classification",
                      `String classification_code );
                    ("configured_label_count", `Int configured_label_count);
                    ("candidate_count", `Int original_candidate_count);
                    ( "tool_filtered_candidate_count",
                      `Int tool_filtered_candidate_count );
                    ( "required_lane_filtered_candidate_count",
                      `Int required_lane_filtered_candidate_count );
                    ( "local_prefiltered_candidate_count",
                      `Int local_prefiltered_candidate_count );
                    ( "unhealthy_local_endpoint_count",
                      `Int (List.length unhealthy_local_endpoints) );
                    ( "unhealthy_local_endpoints",
                      `List
                        (List.map
                           (fun endpoint -> `String endpoint)
                           unhealthy_local_endpoints) );
                    ( "health_filtered_candidate_count",
                      `Int health_filtered_candidate_count );
                    ( "rejected_candidate_count",
                      `Int (List.length provider_rejections) );
                    ( "provider_rejections",
                      `List
                        (List.map
                           (fun r ->
                             `Assoc
                               [
                                 ("provider_label", `String r.provider_label);
                                 ("reason", `String r.reason);
                               ])
                           provider_rejections) );
                    ( "rejection_reasons",
                      `List
                        (List.map
                           (fun reason -> `String reason)
                           provider_rejection_reasons) );
                    ( "require_tool_choice_support",
                      `Bool require_tool_choice_support );
                    ("require_tool_support", `Bool require_tool_support);
                  ]))
           ()
         |> append
       | _ -> ());
      Error
        (sdk_error_of_masc_internal_error internal_error)
  | _ ->
  let candidate_count = List.length candidates in
  let capture, _metrics =
    Cascade_observation.cascade_metrics_for_candidates ~candidate_count ()
  in
  let cascade_strategy_name_ref = ref None in
  let name = Printf.sprintf "oas-%s" cascade_name in
  let transport_resolved = match transport with
    | Some t -> t
    | None -> Masc_grpc_transport.from_env ()
  in
  let queue_priority =
    Option.value priority ~default:Llm_provider.Request_priority.Proactive
  in
  let tier_admission_policy =
    cascade_tier_admission_policy_of_priority queue_priority
  in
  (* MASC-driven cascade FSM: try each provider, decide on failure.
     Extracted to [Keeper_turn_driver_try_provider.run_try_provider] via
     explicit [try_provider_ctx] record (RFC-0051 PR-3a). *)
  let turn_start = Mtime_clock.now () in
  let seq_ref = ref 0 in
  let try_provider_ctx : Keeper_turn_driver_try_provider.try_provider_ctx = {
    cascade_name;
    error_cascade_name;
    keeper_name;
    name;
    goal;
    require_tool_choice_support;
    require_tool_support;
    priority;
    session_id;
    system_prompt;
    tools;
    initial_messages;
    max_turns;
    max_idle_turns;
    stream_idle_timeout_s;
    temperature;
    max_tokens;
    max_input_tokens;
    max_cost_usd;
    guardrails;
    hooks;
    context_reducer;
    memory;
    tool_retry_policy;
    required_tool_satisfaction;
    raw_trace;
    transport_resolved;
    cli_transport_overrides;
    runtime_mcp_policy;
    allowed_paths;
    checkpoint_sidecar;
    cache_system_prompt;
    yield_on_tool;
    compact_ratio;
    oas_auto_context_overflow_retry;
    checkpoint_dir;
    context_injector;
    context;
    slot_id;
    enable_thinking;
    approval;
    exit_condition;
    exit_condition_result;
    summarizer;
    oas_checkpoint;
    contract;
    sw;
    net;
    on_event;
    on_yield;
    on_resume;
    agent_ref;
    proof_ref;
    event_bus;
    cascade_engine;
    runtime_manifest_context;
    runtime_manifest_append;
    runtime_manifest_required_tool_names;
    turn_start;
    seq_ref;
  } in
  let emit_runtime_manifest ?status ?decision ?oas_turn_count event =
    match runtime_manifest_context, runtime_manifest_append with
    | Some manifest_ctx, Some append ->
      let decision =
        match decision with
        | None -> Some (`Assoc (Keeper_cascade_engine.manifest_fields cascade_engine))
        | Some (`Assoc fields) ->
            Some
              (`Assoc
                (Keeper_cascade_engine.manifest_fields cascade_engine @ fields))
      | Some other ->
            Some
              (`Assoc
                (Keeper_cascade_engine.manifest_fields cascade_engine
                 @ [ ("decision", other) ]))
      in
      let decision =
        match runtime_manifest_context with
        | Some manifest_ctx ->
          seq_ref := !seq_ref + 1;
          let elapsed_ms =
            let ns =
              Mtime.Span.to_uint64_ns
                (Mtime.span turn_start (Mtime_clock.now ()))
            in
            Some (Int64.to_int (Int64.div ns 1_000_000L))
          in
          let decision =
            match decision with
            | Some value -> value
            | None -> `Assoc []
          in
          Some
            (Keeper_runtime_manifest.with_clock_refs
               ~clock_refs:
                 (Keeper_runtime_manifest.clock_refs_for_context manifest_ctx
                    ~event ?oas_turn_count ?elapsed_ms
                    ~logical_seq:!seq_ref ())
               decision)
        | None -> decision
      in
      Keeper_runtime_manifest.make_for_context manifest_ctx ~event
        ?oas_turn_count ~logical_seq:!seq_ref ~cascade_name ?status ?decision
        ()
      |> append
    | _ -> ()
  in
  let try_cascade_ctx : Keeper_turn_driver_try_cascade.try_cascade_ctx = {
    cascade_name;
    error_cascade_name;
    keeper_name;
    name;
    candidate_count;
    configured_labels;
    error_selected_model_raw;
    capture;
    cascade_strategy_name_ref;
    try_provider_ctx;
    runtime_manifest_required_tool_names;
    runtime_mcp_policy;
    tools;
    require_tool_choice_support;
    required_lane_provider_rejections;
    emit_runtime_manifest;
    runtime_manifest_context;
    runtime_manifest_append;
    cascade_engine;
    turn_start;
    seq_ref;
    health_cooldown_fail_open;
    base_path;
    session_id;
    tier_admission_policy;
    accept;
    error_cascade_name_for_backpressure = error_cascade_name;
    record_provider_health_result;
    filter_provider_health_fail_open;
    record_provider_health_error;
    wait_timeout_sec;
  } in
  let try_cascade
        ?(on_success = fun ~provider_key:_ -> ())
        ?(pre_dispatch_required_tool_rejections_rev = [])
        ?resume_checkpoint ?per_provider_timeout_s ?last_capacity_source
        ?last_capacity_backpressure remaining last_err =
    Keeper_turn_driver_try_cascade.run
      ~on_success
      ~pre_dispatch_required_tool_rejections_rev
      ?resume_checkpoint ?per_provider_timeout_s ?last_capacity_source
      ?last_capacity_backpressure
      try_cascade_ctx remaining last_err
  in
  (* Pluggable strategy + cycle/backoff wrapper (since 0.9.6).

     When no [<name>_strategy] is configured in cascade.toml,
     [Cascade_config.resolve_strategy] returns [Cascade_strategy.failover]
     with [max_cycles = 1].  In that case [cycle_loop] invokes
     [try_cascade] exactly once on the original [candidate_cfgs] —
     bit-identical to the pre-strategy behaviour (linear failover). *)
  let profile_knob_or_default ~knob ~default resolve =
    match resolve () with
    | Ok value -> Ok value
    | Error detail ->
        Log.Misc.error "cascade %s: %s" cascade_name detail;
        Error (cascade_catalog_error_to_sdk_error detail)
  in
  let* strategy =
    profile_knob_or_default ~knob:"strategy"
      ~default:Cascade_strategy.failover
      (fun () -> Cascade_catalog_runtime.resolve_strategy ~name:cascade_name ())
  in
  let strategy_name = Cascade_strategy.kind_to_string strategy.kind in
  let () = cascade_strategy_name_ref := Some strategy_name in
  let _ = sw, net in
  let adapter = Cascade_runtime_candidate.strategy_adapter in
  let signal_ctx : Cascade_strategy.signal_ctx = {
    health = Cascade_health_tracker.global;
    capacity = Cascade_capacity_probe.capacity;
    now = Unix.gettimeofday ();
    rand_int = Random.int;
    keeper_name;
    cascade_name = error_cascade_name;
  } in
  let cycle_clock = Eio_context.get_clock_opt () in
  let do_backoff cycle =
    let ms = Cascade_strategy.backoff_ms strategy.cycle ~cycle in
    if ms <= 0 then ()
    else
      let secs = float_of_int ms /. 1000. in
      match cycle_clock with
      | Some clock -> Eio.Time.sleep clock secs
      | None ->
        (* No Eio clock available — skip backoff rather than block the
           thread.  Reachable only outside an Eio.Switch, which is not a
           supported entry path for this worker; the cycle simply
           continues without throttling. *)
        ()
  in
  let cascade_exhausted_after_filter ~cycle =
    let observation =
      Cascade_observation.cascade_observation_with_metrics
        ~cascade_name:error_cascade_name
        ?strategy:!cascade_strategy_name_ref ~configured_labels
        ~candidate_count ~selected_model_raw:error_selected_model_raw ~capture ()
    in
    Cascade_observation.record_cascade ~keeper_name
      ~cascade_name:error_cascade_name
      ~outcome:`Failure ~observation:(Some observation) ();
    Error
      (sdk_error_of_masc_internal_error
         (Cascade_exhausted
            {
              cascade_name = error_cascade_name;
              reason = Keeper_types.Candidates_filtered_after_cycles;
            }))
  in
  let record_trace ~cycle ~candidates_out ~backoff_ms ~kind =
    Cascade_strategy_trace.record {
      ts = Unix.gettimeofday ();
      cascade_name = Cascade_name.of_string_exn cascade_name;
      strategy = strategy_name;
      cycle;
      candidates_in = List.length candidates;
      candidates_out;
      backoff_ms;
      kind;
      (* trace_id is left [None] until the keeper_turn_id wired by
         Step 0a is threaded into [try_cascade]; downstream consumers
         (dashboard_cascade, bin/masc_trace) already render [None] as
         a JSON [null] so producers can adopt incrementally. *)
      trace_id = None;
      confidence_score = None;
    }
  in
  let rec cycle_loop n =
    let ordered =
      Cascade_strategy.order_candidates strategy
        ~adapter ~ctx:signal_ctx ~cycle:n candidates
      |> filter_provider_health_fail_open
    in
    let last_cycle = n + 1 >= strategy.cycle.max_cycles in
    match ordered with
    | [] when last_cycle ->
      record_trace ~cycle:n ~candidates_out:0 ~backoff_ms:0 ~kind:Exhausted;
      cascade_exhausted_after_filter ~cycle:n
    | [] ->
      let backoff = Cascade_strategy.backoff_ms strategy.cycle ~cycle:(n + 1) in
      record_trace ~cycle:n ~candidates_out:0 ~backoff_ms:backoff
        ~kind:Filtered_empty;
      Log.Misc.info
        "cascade %s: cycle %d (%s) filtered all candidates, retrying"
        cascade_name n strategy_name;
      do_backoff (n + 1);
      cycle_loop (n + 1)
    | _ ->
      record_trace ~cycle:n ~candidates_out:(List.length ordered)
        ~backoff_ms:0 ~kind:Ordered;
      let on_success ~provider_key =
        Cascade_strategy.record_choice strategy ~ctx:signal_ctx ~provider_key
      in
      (match try_cascade ~on_success ?per_provider_timeout_s ordered None with
       | Ok _ as ok -> ok
       | Error _ as err when last_cycle -> err
       | Error _ ->
         Log.Misc.info
           "cascade %s: cycle %d exhausted, backoff before retry (strategy=%s)"
           cascade_name n strategy_name;
         do_backoff (n + 1);
         cycle_loop (n + 1))
  in
  let admission_cascade_name =
    Cascade_name.of_string_exn cascade_name
  in
  match Admission_queue.with_permit ?wait_timeout_sec
    ~priority:queue_priority ~keeper_name:name ~cascade_name:admission_cascade_name
    (fun () -> cycle_loop 0) with
  | Ok result -> result
  | Error (`Host_resource_saturated reason) ->
      Error
        (sdk_error_of_masc_internal_error
           (Admission_queue_rejected { keeper_name = name; reason })))


module For_testing = struct
  let checkpoint_after_attempt = checkpoint_after_attempt
  let missing_required_tool_names_after_lane_by_name =
    missing_required_tool_names_after_lane_by_name
  let success_selected_model_raw = success_selected_model_raw
  let cascade_tier_admission_policy_of_priority =
    cascade_tier_admission_policy_of_priority
  let with_cascade_tier_admission_for_testing
      ~admission ~enabled ~tier_id ~admission_policy f =
    with_keeper_cascade_tier_admission ~admission ~enabled ~tier_id
      ~admission_policy f
end
