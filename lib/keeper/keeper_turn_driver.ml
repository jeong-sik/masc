(** Keeper_turn_driver — MASC named-cascade and model-label execution entry points.

    Public API for running OAS agents through MASC-managed named cascade
    profiles ([run_named])
    or explicit model label ([run_model_by_label]), with optional MASC
    tool bridging variants.

    @since God file decomposition — extracted from oas_worker.ml *)

open Result.Syntax

(* Sub-module includes (God file decomposition).
   Each sub-module is self-contained; the facade re-exports everything
   so existing callers do not need qualification. *)
include Cascade_oas_runner
include Cascade_error_classify
include Cascade_attempt_fsm
include Keeper_turn_driver_helpers

let provider_attempt_status_of_result = function
  | Ok _ -> "provider_returned"
  | Error (Agent_sdk.Error.Api (Llm_provider.Retry.Timeout _)) -> "timeout"
  | Error (Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _)) -> "timeout"
  | Error _ -> "error"

let provider_attempt_exception_kind_of_result = function
  | Error (Agent_sdk.Error.Api (Llm_provider.Retry.Timeout _)) ->
    Some "outer_oas_timeout"
  | Error (Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _)) ->
    Some "outer_oas_timeout"
  | Ok _ | Error _ -> None

let provider_attempt_status_and_error_of_exception = function
  | Eio.Time.Timeout -> "timeout", "Eio.Time.Timeout"
  | Eio.Cancel.Cancelled inner ->
    ( "cancelled"
    , Printf.sprintf
        "Eio.Cancel.Cancelled(%s)"
        (Printexc.to_string inner) )
  | exn -> "exception", Printexc.to_string exn

type provider_attempt_provenance =
  { model_source : string
  ; resolved_model_source : string
  ; capability_source : string
  ; fallback_authority : string
  ; provider_source_cascade : string option
  }

let base_provider_attempt_provenance =
  { model_source = "named_cascade"
  ; resolved_model_source = "cascade_catalog_binding"
  ; capability_source = "provider_config_from_cascade_catalog"
  ; fallback_authority = "declared_cascade"
  ; provider_source_cascade = None
  }

let provider_attempt_provenance_fields p =
  let base =
    [ ("model_source", `String p.model_source)
    ; ("resolved_model_source", `String p.resolved_model_source)
    ; ("capability_source", `String p.capability_source)
    ; ("fallback_authority", `String p.fallback_authority)
    ]
  in
  match p.provider_source_cascade with
  | None -> base
  | Some source_cascade ->
      ("provider_source_cascade", `String source_cascade) :: base

type provider_attempt_started_record =
  { started_provenance : provider_attempt_provenance
  ; started_is_last : bool
  ; started_per_provider_timeout_s : float option
  }

type provider_attempt_finished_record =
  { finished_provenance : provider_attempt_provenance
  ; finished_status : string
  ; finished_latency_ms : float
  ; finished_checkpoint_after_present : bool
  ; finished_error : Yojson.Safe.t
  ; finished_exception_kind : string option
  }

let provider_attempt_started_decision record =
  `Assoc
    (provider_attempt_provenance_fields record.started_provenance
     @ [
         ("is_last", `Bool record.started_is_last);
         ( "per_provider_timeout_s",
           match record.started_per_provider_timeout_s with
           | None -> `Null
           | Some timeout -> `Float timeout );
       ])
;;

let provider_attempt_finished_decision record =
  let decision_fields =
    [
      ("latency_ms", `Float record.finished_latency_ms);
      ("checkpoint_after_present", `Bool record.finished_checkpoint_after_present);
      ("error", record.finished_error);
    ]
  in
  let decision_fields =
    provider_attempt_provenance_fields record.finished_provenance @ decision_fields
  in
  let decision_fields =
    match record.finished_exception_kind with
    | None -> decision_fields
    | Some kind -> ("exception_kind", `String kind) :: decision_fields
  in
  `Assoc decision_fields
;;

let client_capacity_full_decision ~capacity_key =
  `Assoc
    [ "blocker", `String "client_capacity_full"
    ; "capacity_key", `String capacity_key
    ; "provider_attempt_started", `Bool false
    ]
;;

let success_selected_model_raw candidate =
  Some (Cascade_runtime_candidate.model_health_key candidate)

(* Error/rejected/exhausted observations intentionally leave the concrete
   selected model absent. Downstream attribution uses candidate_models or the
   cascade route for those outcomes. *)
let error_selected_model_raw = None

let health_error_kind label =
  Cascade_health_tracker.error_kind_of_string label

let record_candidate_health_success candidate ~latency_ms =
  Cascade_runtime_candidate.health_keys candidate
  |> List.iter (fun provider_key ->
    Cascade_health_tracker.record_success
      Cascade_health_tracker.global
      ~provider_key
      ~latency_ms
      ())

let record_candidate_health_rejected candidate ~reason =
  let error_kind = health_error_kind "accept_rejected" in
  Cascade_runtime_candidate.health_keys candidate
  |> List.iter (fun provider_key ->
    Cascade_health_tracker.record_rejected
      Cascade_health_tracker.global
      ~provider_key
      ~error_kind
      ~error_reason:reason
      ())

let record_candidate_health_error candidate sdk_err =
  let error_reason = Agent_sdk.Error.to_string sdk_err in
  let health_keys = Cascade_runtime_candidate.health_keys candidate in
  if sdk_error_is_hard_quota sdk_err
  then (
    let error_kind = health_error_kind "hard_quota" in
    health_keys
    |> List.iter (fun provider_key ->
      Cascade_health_tracker.record_hard_quota
        Cascade_health_tracker.global
        ~provider_key
        ~error_kind
        ~error_reason
        ()))
  else if sdk_error_is_terminal_provider_runtime_failure sdk_err
  then (
    let error_kind = health_error_kind "terminal_provider_runtime_failure" in
    health_keys
    |> List.iter (fun provider_key ->
      Cascade_health_tracker.record_terminal_failure
        Cascade_health_tracker.global
        ~provider_key
        ~error_kind
        ~error_reason
        ()))
  else
    match sdk_error_soft_rate_limited sdk_err with
    | Some retry_after_s ->
      let error_kind = health_error_kind "soft_rate_limited" in
      health_keys
      |> List.iter (fun provider_key ->
        Cascade_health_tracker.record_soft_rate_limited
          Cascade_health_tracker.global
          ~provider_key
          ?retry_after_s
          ~error_kind
          ~error_reason
          ())
    | None ->
      let error_kind = health_error_kind "provider_error" in
      health_keys
      |> List.iter (fun provider_key ->
        Cascade_health_tracker.record_failure
          Cascade_health_tracker.global
          ~provider_key
          ~error_kind
          ~error_reason
          ())

let runtime_candidate_label = "runtime"
(* ================================================================ *)
(* Facade-only: run_named, run_model_by_label, and MASC tool bridges  *)
(* ================================================================ *)

(** Run a single Agent.run() call with MASC-driven cascade model fallback.

    MASC drives the cascade FSM directly:
    - Resolves cascade providers from cascade.toml
    - For each provider, runs OAS with a single provider
    - Uses Cascade_fsm.decide to determine next action on failure
    - Cascade loop runs inside Admission_queue permit

    @param accept Optional response validator. Default accepts all.
    @since Phase 2 — MASC-driven cascade FSM *)
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
  let error_cascade_name = cascade_name_of_string cascade_name in
  let runtime_cascade_name = Keeper_cascade_profile.Runtime_name cascade_name in
  let runtime_mcp_policy = runtime_mcp_policy_for_tools ~keeper_name tools in
  (* Keeper-internal tools cannot degrade to a text-only CLI palette: the
     model would see no callable schema and emit misleading diagnostics. *)
  let require_tool_support =
    require_tool_support
    || keeper_internal_tools_require_materialized_runtime_surface
         ~keeper_name tools
  in
  let configured_labels_result, candidate_cfgs_result, secondary_resolver =
    let named_resolution =
      Cascade_catalog_runtime
      .resolve_named_providers_strict_with_secondary_resolver
        ~sw ~net ?provider_filter ~cascade_name ()
    in
    let candidate_cfgs_result =
      match named_resolution with
      | Ok resolution -> Ok resolution.providers
      | Error detail -> Error detail
    in
    let secondary_resolver =
      match named_resolution with
      | Ok resolution -> Some resolution.secondary_resolver
      | Error _ -> None
    in
    ( Cascade_runtime.models_of_cascade_name_result runtime_cascade_name,
      candidate_cfgs_result,
      secondary_resolver )
  in
  (match configured_labels_result, candidate_cfgs_result with
   | Error detail, _ | _, Error detail ->
       Log.Misc.error "cascade %s: %s" cascade_name detail;
       Error (cascade_catalog_error_to_sdk_error detail)
   | Ok configured_labels, Ok candidate_cfgs ->
  let original_candidate_cfgs = candidate_cfgs in
  let original_candidates =
    Cascade_runtime_candidate.of_provider_configs original_candidate_cfgs
  in
  let tool_filtered_candidate_cfgs =
    filter_candidate_providers_for_tool_support
      ~keeper_name
      ?runtime_mcp_policy
      ~tools
      ~require_tool_choice_support
      ~require_tool_support
      ?secondary_resolver
      ~label:cascade_name
      candidate_cfgs
  in
  let configured_label_count = List.length configured_labels in
  let original_candidate_count = List.length original_candidate_cfgs in
  let tool_filtered_candidate_count = List.length tool_filtered_candidate_cfgs in
  let tool_filtered_candidates =
    Cascade_runtime_candidate.of_provider_configs tool_filtered_candidate_cfgs
  in
  let health_filtered_candidates =
    tool_filtered_candidates
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
  let dispatch_seed_candidates, health_cooldown_fail_open =
    fail_open_health_filtered_candidates
      ~tool_filtered_candidates
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
  let provider_attempt_provenance = base_provider_attempt_provenance in
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
    | Provider_error.CapacityExhausted _
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
      in
      let empty_candidate_classification =
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
         local_prefiltered_candidate_count=%d health_filtered_candidate_count=%d \
         require_tool_choice_support=%b require_tool_support=%b"
        cascade_name
        exhaustion_summary
        classification_code
        configured_label_count
        original_candidate_count
        tool_filtered_candidate_count
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
    Cascade_legacy_runner.cascade_metrics_for_candidates ~candidate_count ()
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
  (* MASC-driven cascade FSM: try each provider, decide on failure.
     Extracted to [Keeper_turn_driver_try_provider.run_try_provider] via
     explicit [try_provider_ctx] record (RFC-0051 PR-3a). *)
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
      Keeper_runtime_manifest.make_for_context manifest_ctx ~event
        ?oas_turn_count ~cascade_name ?status ?decision ()
      |> append
    | _ -> ()
  in
          let try_provider ?resume_checkpoint ?per_provider_timeout_s candidate =
            Keeper_turn_driver_try_provider.run_try_provider
              try_provider_ctx
              ?resume_checkpoint
              ?per_provider_timeout_s
              candidate
          in
          let record_cascade_attempt candidate ?http_status ~outcome () =
            match base_path with
            | None -> ()
            | Some base_path ->
              if String.equal (String.trim keeper_name) ""
              then ()
              else
                let record : Keeper_types.cascade_attempt_record =
                  { provider_id = Cascade_runtime_candidate.provider_label candidate
                  ; http_status
                  ; outcome
                  ; timestamp =
                      Unix.gettimeofday ()
                      (* NDT-OK: external provider observation timestamp only. *)
                  }
                in
                Keeper_registry.record_cascade_attempt ~base_path ~keeper_name record
          in
          let http_status_of_provider_error = function
            | Some (Provider_error.ServerError { code; _ }) -> Some code
            | Some
                (Provider_error.CapacityExhausted _
                | Provider_error.RateLimit _
                | Provider_error.AuthError
                | Provider_error.InvalidRequest _
                | Provider_error.CliWrappedHardQuota _
                | Provider_error.CliWrappedMaxTurns _
                | Provider_error.CliWrappedResumableSession _
                | Provider_error.PermissionDenied _
                | Provider_error.ModelNotFound)
            | None -> None
          in
          let positive_finite_float = function
            | value when Float.is_finite value && value > 0.0 -> Some value
    | _ -> None
  in
  let health_error_kind label =
    Cascade_health_tracker.error_kind_of_string label
  in
  let health_keys candidate =
    Cascade_runtime_candidate.health_keys candidate
    |> List.sort_uniq String.compare
  in
  let cost_usd_of_response (response : Agent_sdk.Types.api_response) =
    match response.usage with
    | Some usage -> usage.cost_usd
    | None -> None
  in
  let record_candidate_success candidate ~latency_ms
      (result : Cascade_runner.run_result) =
    let latency_ms = positive_finite_float latency_ms in
    let cost_usd = cost_usd_of_response result.response in
    List.iter
      (fun provider_key ->
         Cascade_health_tracker.record_success
           Cascade_health_tracker.global
           ~provider_key
           ?latency_ms
           ?cost_usd
           ())
      (health_keys candidate)
  in
  let record_candidate_rejected candidate ~reason =
    let error_kind = health_error_kind "accept_rejected" in
    List.iter
      (fun provider_key ->
         Cascade_health_tracker.record_rejected
           Cascade_health_tracker.global
           ~provider_key
           ~error_kind
           ~error_reason:reason
           ())
      (health_keys candidate)
  in
  let record_candidate_error candidate (sdk_err : Agent_sdk.Error.sdk_error) =
    let error_reason = Agent_sdk.Error.to_string sdk_err in
    let error_kind =
      sdk_error_cascade_fallback_class sdk_err
      |> Option.value ~default:"provider_error"
      |> health_error_kind
    in
    let provider_key = Cascade_runtime_candidate.health_key candidate in
    let model_key = Cascade_runtime_candidate.model_health_key candidate in
    if sdk_error_is_hard_quota sdk_err then
      Cascade_health_tracker.record_hard_quota
        Cascade_health_tracker.global
        ~provider_key
        ~error_kind
        ~error_reason
        ()
    else if sdk_error_is_model_access_denied sdk_err then
      Cascade_health_tracker.record_terminal_failure
        Cascade_health_tracker.global
        ~provider_key:model_key
        ~error_kind
        ~error_reason
        ()
    else if sdk_error_is_resumable_cli_session sdk_err
            || sdk_error_is_terminal_provider_runtime_failure sdk_err
    then
      Cascade_health_tracker.record_terminal_failure
        Cascade_health_tracker.global
        ~provider_key
        ~error_kind
        ~error_reason
        ()
    else
      match sdk_error_soft_rate_limited sdk_err with
      | Some retry_after_s ->
        Cascade_health_tracker.record_soft_rate_limited
          Cascade_health_tracker.global
          ~provider_key
          ?retry_after_s
          ~error_kind
          ~error_reason
          ()
      | None ->
        Cascade_health_tracker.record_failure
          Cascade_health_tracker.global
          ~provider_key
          ~error_kind
          ~error_reason
          ()
  in
  let acquire_client_capacity_slot candidate =
    let capacity_key =
      Cascade_runtime_candidate.capacity_key candidate |> String.trim
    in
    if String.equal capacity_key ""
       || not (Cascade_client_capacity.is_registered capacity_key)
    then `No_client_capacity
    else
      match Cascade_client_capacity.try_acquire capacity_key with
      | Some release -> `Acquired (capacity_key, release)
      | None -> `Full capacity_key
  in
  let emit_capacity_blocked_manifest ~capacity_key =
    emit_runtime_manifest
      ~status:"blocked"
      ~decision:(client_capacity_full_decision ~capacity_key)
      Keeper_runtime_manifest.Pre_dispatch_blocked
  in
  let rec try_cascade
      ?(on_success = fun ~provider_key:_ -> ())
      ?resume_checkpoint ?per_provider_timeout_s remaining last_err =
    match remaining with
    | [] ->
      let reason : Keeper_types.cascade_exhaustion_reason = match last_err with
        | Some (Llm_provider.Http_client.NetworkError { message; kind }) ->
            if kind = Llm_provider.Http_client.Connection_refused
               || String_util.contains_substring_ci message "connection refused" then
              Keeper_types.Connection_refused
            else if message_looks_like_cli_wrapped_max_turns message then
              Keeper_types.Max_turns_exceeded
            else
              Keeper_types.Other_detail (Cascade_fsm.to_user_message last_err)
        | Some (Llm_provider.Http_client.TimeoutError { message; _ }) ->
            if message_looks_like_cli_wrapped_max_turns message then
              Keeper_types.Max_turns_exceeded
            else
              Keeper_types.Other_detail (Cascade_fsm.to_user_message last_err)
        | Some (Llm_provider.Http_client.HttpError { body; _ }) ->
            if message_looks_like_cli_wrapped_max_turns body then
              Keeper_types.Max_turns_exceeded
            else
              Keeper_types.Other_detail (Cascade_fsm.to_user_message last_err)
        | Some (Llm_provider.Http_client.AcceptRejected { reason = r }) ->
            if message_looks_like_cli_wrapped_max_turns r then
              Keeper_types.Max_turns_exceeded
            else
              Keeper_types.Other_detail (Cascade_fsm.to_user_message last_err)
        | Some (Llm_provider.Http_client.CliTransportRequired _) ->
            Keeper_types.Other_detail (Cascade_fsm.to_user_message last_err)
        | Some (Llm_provider.Http_client.ProviderTerminal
            { kind = Llm_provider.Http_client.Max_turns _; _ }) ->
            Keeper_types.Max_turns_exceeded
        | Some (Llm_provider.Http_client.ProviderTerminal
            { kind = Llm_provider.Http_client.Other _; _ }) ->
            Keeper_types.Other_detail (Cascade_fsm.to_user_message last_err)
        | Some (Llm_provider.Http_client.ProviderFailure _ as err) ->
            let message = Cascade_fsm.to_user_message (Some err) in
            if message_looks_like_cli_wrapped_max_turns message then
              Keeper_types.Max_turns_exceeded
            else
              Keeper_types.Other_detail message
        | None -> Keeper_types.No_providers_available
      in
      let observation =
        Cascade_legacy_runner.cascade_observation_with_metrics
          ~cascade_name:error_cascade_name
          ?strategy:!cascade_strategy_name_ref ~configured_labels
          ~candidate_count ~selected_model_raw:error_selected_model_raw ~capture ()
      in
      Cascade_legacy_runner.record_cascade ~keeper_name
        ~cascade_name:error_cascade_name
        ~outcome:`Failure ~observation:(Some observation) ();
      let terminal_error =
        match last_err with
        | Some (Llm_provider.Http_client.NetworkError { message; _ })
          when message_looks_like_resumable_cli_session message ->
            sdk_error_of_masc_internal_error
              (Resumable_cli_session
                 {
                   cascade_name = error_cascade_name;
                   detail = resumable_cli_session_detail message;
                   exit_code = resumable_cli_session_exit_code message;
                 })
        | Some (Llm_provider.Http_client.AcceptRejected { reason })
          when message_looks_like_resumable_cli_session reason ->
            sdk_error_of_masc_internal_error
              (Resumable_cli_session
                 {
                   cascade_name = error_cascade_name;
                   detail = resumable_cli_session_detail reason;
                   exit_code = resumable_cli_session_exit_code reason;
                 })
        | _ ->
            sdk_error_of_masc_internal_error
              (Cascade_exhausted
                 {
                   cascade_name = error_cascade_name;
                   reason;
                 })
      in
      Error
        terminal_error
    | candidate :: rest ->
      Eio_guard.fair_yield (); (* P0: keep fast-fail cascades scheduler-fair. *)
      let health_cooldown =
        Cascade_runtime_candidate.first_health_cooldown candidate
      in
      let should_skip_health_cooldown =
        match health_cooldown with
        | None -> false
        | Some _ -> not health_cooldown_fail_open
      in
      if should_skip_health_cooldown then (
        match health_cooldown with
        | Some (_blocked_health_key, msg) ->
            Log.Misc.debug
              "cascade %s: skipping %s (provider_key=%s cooldown: %s)"
              cascade_name runtime_candidate_label runtime_candidate_label msg;
            try_cascade ~on_success ?resume_checkpoint ?per_provider_timeout_s
              rest last_err
        | None ->
            try_cascade ~on_success ?resume_checkpoint ?per_provider_timeout_s
              rest last_err)
      else (
      (match health_cooldown with
       | Some (_blocked_health_key, msg) ->
           Log.Misc.warn
             "cascade %s: attempting %s despite health/cooldown fail-open \
              (provider_key=%s cooldown: %s)"
             cascade_name runtime_candidate_label runtime_candidate_label msg
       | None -> ());
      let is_last = rest = [] in
      match acquire_client_capacity_slot candidate with
      | `Full capacity_key ->
        emit_capacity_blocked_manifest ~capacity_key;
        record_cascade_attempt candidate ~outcome:(`Failure "slot_full") ();
        Cascade_legacy_runner.record_fallback_event capture
          ~from_model:runtime_candidate_label
          ~to_model:runtime_candidate_label
          ~reason:"client_capacity_full";
        Log.Misc.info
          "[cascade-fallback] cascade %s: %s skipped because client capacity \
           key %s is full, trying next"
          cascade_name
          runtime_candidate_label
          capacity_key;
        let slot_last_err =
          match
            Cascade_fsm.decide
              ~accept_on_exhaustion:false
              ~is_last
              Cascade_fsm.Slot_full
          with
          | Cascade_fsm.Try_next { last_err = Some err }
          | Cascade_fsm.Exhausted { last_err = Some err } ->
            Some err
          | Cascade_fsm.Try_next { last_err = None }
          | Cascade_fsm.Exhausted { last_err = None } ->
            last_err
          | Cascade_fsm.Accept _
          | Cascade_fsm.Accept_on_exhaustion _ ->
            last_err
        in
        try_cascade ~on_success ?resume_checkpoint ?per_provider_timeout_s
          rest slot_last_err
      | (`No_client_capacity | `Acquired _) as capacity_slot ->
      let capacity_release =
        match capacity_slot with
        | `Acquired (_capacity_key, release) -> Some release
        | `No_client_capacity -> None
        | `Full _ -> None
      in
      Log.Misc.debug "cascade %s: trying %s (is_last=%b)" cascade_name runtime_candidate_label is_last;
      let pp_timeout =
        Cascade_runtime_candidate.effective_attempt_timeout_s
          ~is_last
          ~configured_timeout_s:per_provider_timeout_s
          candidate
      in
      let attempt_started_at = Unix.gettimeofday () in
      let started_record =
        { started_provenance = provider_attempt_provenance
        ; started_is_last = is_last
        ; started_per_provider_timeout_s = pp_timeout
        }
      in
      let provider_attempt_finished_emitted = ref false in
      let emit_provider_attempt_finished_once
            ~status
            ?oas_turn_count
            ~checkpoint_after_present
            ~response_model:_
            ~error
            ?exception_kind
            attempt_latency_ms
        =
        if not !provider_attempt_finished_emitted then (
          provider_attempt_finished_emitted := true;
          let finished_record =
            { finished_provenance = provider_attempt_provenance
            ; finished_status = status
            ; finished_latency_ms = attempt_latency_ms
            ; finished_checkpoint_after_present = checkpoint_after_present
            ; finished_error = error
            ; finished_exception_kind = exception_kind
            }
          in
          emit_runtime_manifest
            ~status
            ?oas_turn_count
            ~decision:(provider_attempt_finished_decision finished_record)
            Keeper_runtime_manifest.Provider_attempt_finished)
      in
      let record_attempt_terminal ~error attempt_latency_ms =
        let latency_ms =
          if Float.is_finite attempt_latency_ms && attempt_latency_ms >= 0.0
          then Some (int_of_float attempt_latency_ms)
          else None
        in
        Cascade_legacy_runner.record_attempt_terminal capture
          ~model_id:runtime_candidate_label ~latency_ms ~error
      in
      let (result, checkpoint_after, liveness_success_sample, attempt_latency_ms) =
        Eio.Switch.run (fun provider_attempt_sw ->
          Option.iter
            (fun release -> Eio.Switch.on_release provider_attempt_sw release)
            capacity_release;
          emit_runtime_manifest
            ~status:"started"
            ~decision:(provider_attempt_started_decision started_record)
            Keeper_runtime_manifest.Provider_attempt_started;
          Eio.Switch.on_release provider_attempt_sw (fun () ->
            if not !provider_attempt_finished_emitted then
              let attempt_latency_ms =
                (Unix.gettimeofday () -. attempt_started_at) *. 1000.0
              in
              Eio.Cancel.protect (fun () ->
                emit_provider_attempt_finished_once
                  ~status:"cancelled"
                  ~checkpoint_after_present:false
                  ~response_model:`Null
                  ~error:
                    (`String
                      "provider attempt scope released before completion; parent \
                       cancellation or outer timeout interrupted the attempt")
                  ~exception_kind:"cancelled"
                  attempt_latency_ms;
                record_attempt_terminal
                  ~error:
                    (Some
                       "provider attempt scope released before completion; parent \
                        cancellation or outer timeout interrupted the attempt")
                  attempt_latency_ms));
          match
            try_provider
              ?resume_checkpoint
              ?per_provider_timeout_s:pp_timeout
              candidate
          with
          | result, checkpoint_after, liveness_success_sample ->
            let attempt_latency_ms =
              (Unix.gettimeofday () -. attempt_started_at) *. 1000.0
            in
            emit_provider_attempt_finished_once
              ~status:(provider_attempt_status_of_result result)
              ?oas_turn_count:
                (match result with
                 | Ok run_result -> Some run_result.turns
                 | Error _ -> None)
              ~checkpoint_after_present:(Option.is_some checkpoint_after)
              ~response_model:
                (match result with
                 | Ok _ -> `Null
                 | Error _ -> `Null)
              ~error:
                (match result with
                 | Ok _ -> `Null
                 | Error sdk_err -> `String (Agent_sdk.Error.to_string sdk_err))
              ?exception_kind:(provider_attempt_exception_kind_of_result result)
              attempt_latency_ms;
            record_attempt_terminal
              ~error:
                (match result with
                 | Ok _ -> None
                 | Error sdk_err -> Some (Agent_sdk.Error.to_string sdk_err))
              attempt_latency_ms;
            result, checkpoint_after, liveness_success_sample, attempt_latency_ms
          | exception exn ->
            let bt = Printexc.get_raw_backtrace () in
            let attempt_latency_ms =
              (Unix.gettimeofday () -. attempt_started_at) *. 1000.0
            in
            let status, error = provider_attempt_status_and_error_of_exception exn in
            emit_provider_attempt_finished_once
              ~status
              ~checkpoint_after_present:false
              ~response_model:`Null
              ~error:(`String error)
              ~exception_kind:status
              attempt_latency_ms;
            record_attempt_terminal ~error:(Some error) attempt_latency_ms;
            Printexc.raise_with_backtrace exn bt)
      in
      let record_accepted_liveness_sample () =
        match liveness_success_sample with
        | None -> ()
        | Some (candidate_key, sample) ->
          Cascade_attempt_liveness_config.record_success_sample
            ~candidate_key
            sample
      in
      (* Thread checkpoint forward: if this provider made progress,
         the next provider can resume from where this one left off. *)
      let next_resume = match checkpoint_after with
        | Some _ -> checkpoint_after
        | None -> resume_checkpoint
      in
      (* Track provider call outcome for weighted-routing health.
         Semantics: response arrived = provider healthy (even if accept
         logic later rejects); error = provider unhealthy.  The
         cascade-decision branches (Accept_on_exhaustion / Try_next /
         Exhausted) are orthogonal to provider health.

         [attempt_latency_ms] is wall-clock from the moment we entered
         [try_provider] to the moment it returned, measured even if the
         response is later rejected by [accept] — but only the Ok+accept
         branch feeds it to the tracker, so unhealthy providers do not
         pollute the per-provider p50/p95.  The 200ms-timeout / 200ms-
         success conflation that would otherwise occur is intentional
         to avoid: a fast failure looks identical to a fast success in
         a single number, which would mislead strategy ranking. *)
      (match result with
      | Ok result when accept result.response ->
        record_provider_health_result candidate ~success:true ~http_status:None;
        record_accepted_liveness_sample ();
        record_candidate_success candidate ~latency_ms:attempt_latency_ms result;
        (* FSM: Call_ok → Accept *)
        let observation =
          Cascade_legacy_runner.cascade_observation_with_metrics
            ~cascade_name:error_cascade_name
            ?strategy:!cascade_strategy_name_ref ~configured_labels
            ~candidate_count ~selected_model_raw:(success_selected_model_raw candidate)
            ~capture ()
        in
        let result = { result with cascade_observation = Some observation } in
                Cascade_legacy_runner.record_cascade ~keeper_name
                  ~cascade_name:error_cascade_name
                  ~outcome:`Success ~observation:(Some observation) ();
                record_cascade_attempt candidate ~outcome:`Success ();
                on_success ~provider_key:(Cascade_runtime_candidate.health_key candidate);
                Ok result
      | Ok result ->
        (* Response arrived but failed the cascade's [accept] predicate
           (empty body, schema gate, etc.).  Prior to 0.160.0 this
           called [record_success] on the rationale that "the provider
           answered"; that masked gate drift because provider health
           stayed 100% while every call fell through to the next tier.
           [record_rejected] behaves like a failure for cooldown /
           weight but keeps the [Rejected] tag so the dashboard can
           distinguish it from hard errors. *)
        (* FSM: Accept_rejected → decide *)
        let reason = "response rejected by accept" in
        record_candidate_rejected candidate ~reason;
        let outcome = Cascade_fsm.Accept_rejected
          { response = result.response; reason } in
        (match Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last outcome with
           | Cascade_fsm.Accept_on_exhaustion { response; _ } ->
           record_provider_health_result candidate ~success:true ~http_status:None;
           record_accepted_liveness_sample ();
           record_candidate_success candidate ~latency_ms:attempt_latency_ms result;
           let observation =
             Cascade_legacy_runner.cascade_observation_with_metrics
               ~cascade_name:error_cascade_name
               ?strategy:!cascade_strategy_name_ref ~configured_labels
               ~candidate_count ~selected_model_raw:(success_selected_model_raw candidate)
               ~capture ()
           in
           let result = { result with cascade_observation = Some observation } in
                   Cascade_legacy_runner.record_cascade ~keeper_name
                     ~cascade_name:error_cascade_name
                     ~outcome:`Success ~observation:(Some observation) ();
                   record_cascade_attempt candidate ~outcome:`Success ();
                   on_success ~provider_key:(Cascade_runtime_candidate.health_key candidate);
                   Ok result
         | Cascade_fsm.Try_next { last_err = new_err } ->
           (* Demoted from WARN to INFO (task-239): cascade will retry the
              next tier.  Tagged [cascade-fallback] so dashboard filters
              can distinguish recovery-in-progress from hard failures. *)
           record_candidate_health_rejected candidate ~reason;
           Log.Misc.info "[cascade-fallback] cascade %s: accept rejected %s (%s), trying next" cascade_name runtime_candidate_label reason;
           Cascade_legacy_runner.record_fallback_event capture
             ~from_model:runtime_candidate_label ~to_model:runtime_candidate_label ~reason;
           (* The rejected response is not trusted progress.  Resuming
              from its checkpoint can turn a fallback provider into a
              replay of the rejected empty/schema-invalid turn. *)
           try_cascade ?resume_checkpoint (filter_provider_health_fail_open rest) new_err
         | Cascade_fsm.Exhausted _ ->
           record_candidate_health_rejected candidate ~reason;
           let observation =
             Cascade_legacy_runner.cascade_observation_with_metrics
               ~cascade_name:error_cascade_name
               ?strategy:!cascade_strategy_name_ref ~configured_labels
               ~candidate_count ~selected_model_raw:error_selected_model_raw
               ~capture ()
           in
           Cascade_legacy_runner.record_cascade ~keeper_name
             ~cascade_name:error_cascade_name
             ~outcome:`Rejected ~observation:(Some observation) ();
           Log.Misc.error "cascade %s exhausted: all tiers rejected by accept predicate (last runtime=%s, reason=%s)"
             cascade_name runtime_candidate_label reason;
           Error
             (sdk_error_of_masc_internal_error
                (Accept_rejected
                   {
                     scope = cascade_name;
                     model = Some runtime_candidate_label;
                     reason;
                   }))
           | Cascade_fsm.Accept _resp ->
           (* Should be unreachable with accept_on_exhaustion:false, but handle gracefully.
              Iter 42: tick an invariant-violation counter so this
              never-supposed-to-fire arm becomes a hard alert if it
              ever does.  Steady-state value is ZERO; non-zero is a
              real FSM contract violation, not a tunable. *)
           Cascade_metrics.on_cascade_invariant_violation ();
           Log.Misc.warn "cascade %s: unexpected Accept in Accept_rejected branch (runtime=%s)" cascade_name runtime_candidate_label;
           record_provider_health_result candidate ~success:true ~http_status:None;
           record_accepted_liveness_sample ();
           record_candidate_success candidate ~latency_ms:attempt_latency_ms result;
           let observation =
             Cascade_legacy_runner.cascade_observation_with_metrics
               ~cascade_name:error_cascade_name
               ?strategy:!cascade_strategy_name_ref ~configured_labels
               ~candidate_count ~selected_model_raw:(success_selected_model_raw candidate)
               ~capture ()
           in
           let result = { result with cascade_observation = Some observation } in
                   Cascade_legacy_runner.record_cascade ~keeper_name
                     ~cascade_name:error_cascade_name
                     ~outcome:`Success ~observation:(Some observation) ();
                   record_cascade_attempt candidate ~outcome:`Success ();
                   on_success ~provider_key:(Cascade_runtime_candidate.health_key candidate);
                   Ok result)
      | Error sdk_err ->
        let sdk_err =
          match
            sdk_error_to_resumable_cli_session
              ~cascade_name:error_cascade_name sdk_err
          with
          | Some err -> err
          | None -> sdk_err
        in
        (* Classify deterministic non-transient failures distinctly from
           ordinary call errors.  Hard quota (e.g. Anthropic multi-day usage
           limit, ZAI balance 0) and Kimi CLI resumable-session conflicts do
           not recover within the 60s [cooldown_sec]; apply an immediate long
           cooldown so weighted_random/failover selection does not waste later
           cascade turns on a provider that is terminal for the current runtime
           state. *)
        let err_str = Agent_sdk.Error.to_string sdk_err in
        record_candidate_health_error candidate sdk_err;
        let provider_error =
          emit_sdk_provider_error_metric
            ~cascade_name:error_cascade_name
            ~provider:runtime_candidate_label
            sdk_err
        in
        record_cascade_attempt
          candidate
          ?http_status:(http_status_of_provider_error provider_error)
          ~outcome:(`Failure (Agent_sdk.Error.to_string sdk_err))
          ();
        Option.iter (record_provider_health_error candidate) provider_error;
        let _ = err_str in
        let cascade_outcome = sdk_error_to_cascade_outcome sdk_err in
        Option.iter
          (fun _ -> record_candidate_error candidate sdk_err)
          cascade_outcome;
        (* FSM: Call_err → decide.
           Hard-quota fast-path: a hard quota is permanent for this turn —
           every remaining tier in this declared cascade will hit the same
           account-level limit, so retrying burns the full OAS turn budget
           (~60min) for nothing.  Force
           [Exhausted] regardless of [is_last] so the agent loop sees the
           terminal error immediately.  The hard-quota cooldown recorded
           above (line ~1760) keeps this provider deselected for future
           turns; the fast-path only short-circuits the within-turn
           retry. *)
        (match cascade_outcome with
         | Some outcome ->
           let decision =
             if sdk_error_is_hard_quota sdk_err then
               let last_err = match outcome with
                 | Cascade_fsm.Call_err e -> Some e
                 (* Non-error provider outcomes carry no http_error to surface
                    as the terminal cause when forcing Exhausted on hard
                    quota.  Enumerated explicitly so a future addition to
                    [Cascade_fsm.provider_outcome] is flagged at compile time
                    instead of silently mapping to [None]. *)
                 | Cascade_fsm.Call_ok _
                 | Cascade_fsm.Accept_rejected _
                 | Cascade_fsm.Slot_full -> None
               in
               Cascade_fsm.Exhausted { last_err }
             else
               Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last outcome
           in
           (match decision with
            | Cascade_fsm.Try_next { last_err = new_err } ->
              (* Demoted from WARN to INFO (task-239): cascade will retry
                 the next tier.  Tagged [cascade-fallback] so dashboards
                 and log filters can distinguish recovery-in-progress
                 from hard failures.  The exec layer's per-tier
                 "agent errored" log was also demoted to DEBUG in the
                 same change, so this INFO is the canonical per-tier
                 signal.

                 #10629: prepend a classification label so
                 [cli_wrapped_max_turns] and [hard_quota] inside
                 NetworkError messages stay legible at the dashboard /
                 log-grep layer.  Pre-fix the log read "Network error:
                 claude exited with code 1: {...subtype error_max_turns...}"
                 which masked that this was a graceful turn-budget exit
                 (33/day claude_code, 2.5x growth). *)
              let class_label =
                match sdk_error_cascade_fallback_class sdk_err with
                | Some class_name -> Printf.sprintf "[%s] " class_name
                | None -> ""
              in
              (* #10982: [max_turns] failures cost ~$2.74 mean per
                 fallback (24h sample: 11 events / $30.20 sunk).  The
                 cost is incurred but the result is unusable, so the
                 next tier re-runs from scratch.  At INFO this signal
                 was buried in normal cascade traffic and the cost
                 dashboard never saw it.  Promote [max_turns] to WARN
                 — still "expected, recoverable" (the cascade escape
                 hatch worked) but visible enough that operators can
                 correlate cost gauges with cascade traffic.
                 [hard_quota] stays INFO for now: quota signals fire
                 normally during ratelimits and warrant a different
                 promotion threshold (separate issue). *)
              if sdk_error_is_max_turns_exceeded sdk_err then
                Log.Misc.warn
                  "[cascade-fallback] cascade %s: %s failed (%s%s), trying \
                   next [sunk cost; see #10982]"
                  cascade_name runtime_candidate_label class_label
                  (Agent_sdk.Error.to_string sdk_err)
              else
                Log.Misc.info
                  "[cascade-fallback] cascade %s: %s failed (%s%s), trying next"
                  cascade_name runtime_candidate_label class_label
                  (Agent_sdk.Error.to_string sdk_err);
              Cascade_legacy_runner.record_fallback_event capture
                ~from_model:runtime_candidate_label ~to_model:runtime_candidate_label
                ~reason:(class_label ^ Agent_sdk.Error.to_string sdk_err);
              let retry_resume_checkpoint =
                if sdk_error_is_server_rejected_parse_error sdk_err then (
                  Log.Misc.info
                    "[cascade-fallback] cascade %s: %s server rejected the \
                     resumed request body; dropping resume checkpoint for \
                     next provider"
                    cascade_name runtime_candidate_label;
                  None)
                else
                  next_resume
              in
              try_cascade
                ?resume_checkpoint:retry_resume_checkpoint
                (filter_provider_health_fail_open rest)
                new_err
            | Cascade_fsm.Exhausted _ ->
              let observation =
                Cascade_legacy_runner.cascade_observation_with_metrics
                  ~cascade_name:error_cascade_name
                  ?strategy:!cascade_strategy_name_ref ~configured_labels
                  ~candidate_count ~selected_model_raw:error_selected_model_raw ~capture ()
              in
              Cascade_legacy_runner.record_cascade ~keeper_name
                ~cascade_name:error_cascade_name
                ~outcome:`Failure ~observation:(Some observation) ();
              Log.Misc.error "cascade %s exhausted: all tiers failed (last runtime=%s, error=%s)"
                cascade_name runtime_candidate_label (Agent_sdk.Error.to_string sdk_err);
              Error sdk_err
            (* [Accept] / [Accept_on_exhaustion] are reachable only from
               [Cascade_fsm.Call_ok] / [Accept_rejected] outcomes, but this
               branch handles a [Call_err] outcome so the FSM cannot return
               them here.  Surface the original sdk_err and let the caller
               see the unexpected mapping rather than silently absorbing a
               new decision variant added to [Cascade_fsm.decision]. *)
            | Cascade_fsm.Accept _
            | Cascade_fsm.Accept_on_exhaustion _ -> Error sdk_err)
         | None ->
           (* Non-API error (agent, config, etc.) — not cascadeable *)
           let observation =
             Cascade_legacy_runner.cascade_observation_with_metrics
               ~cascade_name:error_cascade_name
               ?strategy:!cascade_strategy_name_ref ~configured_labels
               ~candidate_count ~selected_model_raw:error_selected_model_raw ~capture ()
           in
           Cascade_legacy_runner.record_cascade ~keeper_name
             ~cascade_name:error_cascade_name
             ~outcome:`Failure ~observation:(Some observation) ();
           Log.Misc.error "cascade %s: non-cascadable error from %s: %s"
             cascade_name runtime_candidate_label (Agent_sdk.Error.to_string sdk_err);
           Error sdk_err)))
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
      Cascade_legacy_runner.cascade_observation_with_metrics
        ~cascade_name:error_cascade_name
        ?strategy:!cascade_strategy_name_ref ~configured_labels
        ~candidate_count ~selected_model_raw:error_selected_model_raw ~capture ()
    in
    Cascade_legacy_runner.record_cascade ~keeper_name
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
      cascade_name = Keeper_cascade_profile.Runtime_name cascade_name;
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
    Keeper_cascade_profile.runtime_name_of_string cascade_name
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
end
