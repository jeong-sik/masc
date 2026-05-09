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

(* ================================================================ *)
(* Facade-only: run_named, run_model_by_label, and MASC tool bridges  *)
(* ================================================================ *)

(** Run a single Agent.run() call with MASC-driven cascade model fallback.

    MASC drives the cascade FSM directly:
    - Resolves cascade providers from cascade.json
    - For each provider, runs OAS with a single provider
    - Uses Cascade_fsm.decide to determine next action on failure
    - Cascade loop runs inside Admission_queue permit

    @param accept Optional response validator. Default accepts all.
    @since Phase 2 — MASC-driven cascade FSM *)
let run_named
    ~cascade_name
    ?(keeper_name = "")
    ?model_strings
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
    ?(temperature = Cascade_legacy_runner.default_temperature)
    ?(max_tokens = Cascade_legacy_runner.default_max_tokens)
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
    ?sw
    ?net
    ?per_provider_timeout_s
    ()
  : (Cascade_runner.run_result, Agent_sdk.Error.sdk_error) result =
  match require_eio ?sw ?net () with
  | Error e -> Error (eio_context_error_to_sdk_error e)
  | Ok (sw, net) ->
  let cascade_name =
    let trimmed = String.trim cascade_name in
    if Option.is_some model_strings && trimmed <> "" then trimmed
    else Keeper_cascade_profile.normalize_declared_name cascade_name
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
    match model_strings with
    | Some ms when ms <> [] ->
      (* Direct model strings from keeper TOML — skip named preset lookup.
         MASC passes these strings through without interpretation. PR-9b
         secondary declarations are a named-cascade feature, so direct
         model strings must not inherit profile-specific fallback behavior. *)
      ( Ok ms,
        Ok
          (resolve_providers_from_model_strings ?provider_filter
             ?runtime_mcp_policy
             ~require_tool_choice_support ~require_tool_support ms),
        None )
    | _ ->
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
  let candidate_cfgs =
    filter_candidate_providers_for_tool_support
      ~keeper_name
      ?provider_filter
      ?runtime_mcp_policy
      ~tools
      ~require_tool_choice_support
      ~require_tool_support
      ?secondary_resolver
      ~label:cascade_name
      candidate_cfgs
  in
  let candidate_cfgs =
    List.filter
      (fun (provider_cfg : Llm_provider.Provider_config.t) ->
         match first_health_cooldown provider_cfg with
         | None -> true
         | Some (provider_health_key, msg) ->
             Log.Misc.debug
               "cascade %s: prefilter skipped %s (provider_key=%s cooldown: %s)"
               cascade_name provider_cfg.model_id provider_health_key msg;
             false)
      candidate_cfgs
  in
  (* Cross-cascade health-aware fallback: when the current cascade has no
     tool-capable providers after filtering, search all other cascades for
     a healthy tool-capable provider. Depth 1 only (no recursive search). *)
  let candidate_cfgs =
    match candidate_cfgs with
    | [] ->
        (match resolve_tool_capable_provider_across_cascades
                ~sw ~net ~keeper_name ?provider_filter ?runtime_mcp_policy ~tools
                ~require_tool_choice_support ~require_tool_support
                ~exclude_cascade:cascade_name ()
         with
         | Some (source_cascade, provider_cfg) ->
             Prometheus.inc_counter cross_cascade_fallback_metric
               ~labels:[
                 ("from_cascade", cascade_name);
                 ("to_cascade", source_cascade);
                 ("provider",
                  Provider_tool_support.provider_debug_label provider_cfg);
               ]
               ();
             (* §7.3.2 Zero Silent Failure: feed the unified fallback
                counter so the dashboard panel sees a single numerator
                across all fallback classes (cross_cascade,
                cascade_empty, capability_drop, …). *)
             Llm_metric_bridge.emit_fallback_triggered
               ~kind:"cross_cascade"
               ~detail:
                 (Printf.sprintf "%s->%s" cascade_name source_cascade);
             Log.Misc.info
               "cascade %s: cross-cascade fallback to %s from %s \
                (original had no tool-capable providers)"
               cascade_name
               (Provider_tool_support.provider_debug_label provider_cfg)
               source_cascade;
             [provider_cfg]
         | None ->
             Log.Misc.error
               "cascade %s: no callable models available (cross-cascade \
                search also failed) — configured=[%s] \
                require_tool_choice_support=%b require_tool_support=%b"
               cascade_name
               (String.concat ", " configured_labels)
               require_tool_choice_support
               require_tool_support;
             [])
    | _ -> candidate_cfgs
  in
  match candidate_cfgs with
  | [] ->
      let required_tool_names =
        required_tool_names_for_no_tool_error ~runtime_mcp_policy ~tools
      in
      let provider_rejections =
        provider_rejections_for_no_tool_error
          ~keeper_name ?runtime_mcp_policy ~tools
          ~require_tool_choice_support ~require_tool_support
          original_candidate_cfgs
      in
      Error
        (sdk_error_of_masc_internal_error
           (if require_tool_choice_support || require_tool_support then
              No_tool_capable_provider
                {
                  cascade_name = error_cascade_name;
                  configured_labels;
                  required_tool_names;
                  provider_rejections;
                }
            else
              Cascade_exhausted
                {
                  cascade_name = error_cascade_name;
                  reason = Keeper_types.No_providers_available;
                }))
  | _ ->
  let capture, _metrics =
    Cascade_legacy_runner.cascade_metrics_for_candidates ~candidate_cfgs ()
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
  } in
  let try_provider ?resume_checkpoint ?per_provider_timeout_s provider_cfg =
    Keeper_turn_driver_try_provider.run_try_provider
      try_provider_ctx
      ?resume_checkpoint
      ?per_provider_timeout_s
      provider_cfg
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
          ~candidate_cfgs ~selected_model_raw:None ~capture ()
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
    | (provider_cfg : Llm_provider.Provider_config.t) :: rest ->
      Eio_guard.fair_yield (); (* P0: keep fast-fail cascades scheduler-fair. *)
      let provider_health_key =
        Provider_adapter.provider_health_key_of_config provider_cfg
      in
      let provider_model_health_key =
        Provider_adapter.provider_model_health_key_of_config provider_cfg
      in
      match first_health_cooldown provider_cfg with
      | Some (blocked_health_key, msg) ->
          Log.Misc.debug
            "cascade %s: skipping %s (provider_key=%s cooldown: %s)"
            cascade_name provider_cfg.model_id blocked_health_key msg;
          try_cascade ~on_success ?resume_checkpoint ?per_provider_timeout_s rest last_err
      | None ->
      let is_last = rest = [] in
      Log.Misc.debug "cascade %s: trying %s (is_last=%b)" cascade_name provider_cfg.model_id is_last;
      let pp_timeout =
        effective_provider_attempt_timeout_s
          ~is_last
          ~configured_timeout_s:per_provider_timeout_s
          provider_cfg
      in
      let attempt_started_at = Unix.gettimeofday () in
      let (result, checkpoint_after) = try_provider ?resume_checkpoint ?per_provider_timeout_s:pp_timeout provider_cfg in
      let attempt_latency_ms =
        (Unix.gettimeofday () -. attempt_started_at) *. 1000.0
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
        Cascade_health_tracker.(record_success global ~provider_key:provider_health_key
          ~latency_ms:attempt_latency_ms ());
        (* FSM: Call_ok → Accept *)
        let observation =
          Cascade_legacy_runner.cascade_observation_with_metrics
            ~cascade_name:error_cascade_name
            ?strategy:!cascade_strategy_name_ref ~configured_labels
            ~candidate_cfgs ~selected_model_raw:(Some result.response.model)
            ~capture ()
        in
        let result = { result with cascade_observation = Some observation } in
        Cascade_legacy_runner.record_cascade ~keeper_name
          ~cascade_name:error_cascade_name
          ~outcome:`Success ~observation:(Some observation) ();
        on_success ~provider_key:provider_health_key;
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
        Cascade_health_tracker.(
          record_rejected global ~provider_key:provider_health_key
            ~error_kind:(error_kind_of_string "accept_rejected") ());
        (* FSM: Accept_rejected → decide *)
        let reason = Printf.sprintf "response rejected by accept (model=%s)" result.response.model in
        let outcome = Cascade_fsm.Accept_rejected
          { response = result.response; reason } in
        (match Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last outcome with
         | Cascade_fsm.Accept_on_exhaustion { response; _ } ->
           let observation =
             Cascade_legacy_runner.cascade_observation_with_metrics
               ~cascade_name:error_cascade_name
               ?strategy:!cascade_strategy_name_ref ~configured_labels
               ~candidate_cfgs ~selected_model_raw:(Some response.model)
               ~capture ()
           in
           let result = { result with cascade_observation = Some observation } in
           Cascade_legacy_runner.record_cascade ~keeper_name
             ~cascade_name:error_cascade_name
             ~outcome:`Success ~observation:(Some observation) ();
           on_success ~provider_key:provider_health_key;
           Ok result
         | Cascade_fsm.Try_next { last_err = new_err } ->
           (* Demoted from WARN to INFO (task-239): cascade will retry the
              next tier.  Tagged [cascade-fallback] so dashboard filters
              can distinguish recovery-in-progress from hard failures. *)
           Log.Misc.info "[cascade-fallback] cascade %s: accept rejected %s (%s), trying next" cascade_name provider_cfg.model_id reason;
           Cascade_legacy_runner.record_fallback_event capture ~candidate_cfgs
             ~from_model:provider_cfg.model_id ~to_model:"next" ~reason;
           (* The rejected response is not trusted progress.  Resuming
              from its checkpoint can turn a fallback provider into a
              replay of the rejected empty/schema-invalid turn. *)
           try_cascade ?resume_checkpoint rest new_err
         | Cascade_fsm.Exhausted _ ->
           let observation =
             Cascade_legacy_runner.cascade_observation_with_metrics
               ~cascade_name:error_cascade_name
               ?strategy:!cascade_strategy_name_ref ~configured_labels
               ~candidate_cfgs ~selected_model_raw:(Some result.response.model)
               ~capture ()
           in
           Cascade_legacy_runner.record_cascade ~keeper_name
             ~cascade_name:error_cascade_name
             ~outcome:`Rejected ~observation:(Some observation) ();
           Log.Misc.error "cascade %s exhausted: all tiers rejected by accept predicate (last model=%s, reason=%s)"
             cascade_name result.response.model reason;
           Error
             (sdk_error_of_masc_internal_error
                (Accept_rejected
                   {
                     scope = cascade_name;
                     model = Some result.response.model;
                     reason;
                   }))
         | Cascade_fsm.Accept resp ->
           (* Should be unreachable with accept_on_exhaustion:false, but handle gracefully *)
           Log.Misc.warn "cascade %s: unexpected Accept in Accept_rejected branch (model=%s)" cascade_name resp.model;
           let observation =
             Cascade_legacy_runner.cascade_observation_with_metrics
               ~cascade_name:error_cascade_name
               ?strategy:!cascade_strategy_name_ref ~configured_labels
               ~candidate_cfgs ~selected_model_raw:(Some resp.model) ~capture ()
           in
           let result = { result with cascade_observation = Some observation } in
           Cascade_legacy_runner.record_cascade ~keeper_name
             ~cascade_name:error_cascade_name
             ~outcome:`Success ~observation:(Some observation) ();
           on_success ~provider_key:provider_health_key;
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
        let (_ : Provider_error.t option) =
          emit_sdk_provider_error_metric ~cascade_name:error_cascade_name
            ~provider:provider_cfg.model_id sdk_err
        in
        if sdk_error_is_hard_quota sdk_err then
          Cascade_health_tracker.(
            record_hard_quota global ~provider_key:provider_health_key
              ~error_kind:(error_kind_of_string "hard_quota")
              ~error_reason:err_str ())
        else if sdk_error_is_model_access_denied sdk_err then
          Cascade_health_tracker.(
            record_terminal_failure global ~provider_key:provider_model_health_key
              ~error_kind:(error_kind_of_string "model_access_denied")
              ~error_reason:err_str ())
        else if sdk_error_is_resumable_cli_session sdk_err
                || sdk_error_is_terminal_provider_runtime_failure sdk_err
        then
          Cascade_health_tracker.(
            record_terminal_failure global ~provider_key:provider_health_key
              ~error_kind:
                (error_kind_of_string
                   (if sdk_error_is_resumable_cli_session sdk_err then
                      "resumable_cli_session"
                    else
                      "terminal_provider_runtime"))
              ~error_reason:err_str ())
        else (match sdk_error_soft_rate_limited sdk_err with
        | Some retry_after_opt ->
          (* Transient 429 (not a hard quota in disguise).  Trip an
             immediate short cooldown so the next selection tick falls
             over to a different provider; honor [retry_after] when the
             upstream parsed one out of the response body, otherwise let
             the tracker apply [soft_rate_limit_cooldown_sec] (10s default).
             Caller is responsible for upgrading sustained 429 bursts to
             hard_quota; the tracker's max-clamp guards against a
             misclassified hard quota silently producing a long blackout. *)
          Cascade_health_tracker.(
            record_soft_rate_limited global ~provider_key:provider_health_key
              ?retry_after_s:retry_after_opt
              ~error_kind:(error_kind_of_string "http_429")
              ~error_reason:err_str ())
        | None -> (
          (* Classify the err_str into named buckets so Cascade_health_tracker
             fingerprint groups separate codex internal-state corruption
             (transient_codex_rollout — auto-recovers on next call) from
             provider-permanent failures (e.g. kimi_cli auth-rejected) and
             generic CLI exit (network_other).  Without this, every
             [stop=error] is grouped under a single "failure" kind and
             dashboards can't tell a known-recoverable bug pattern from a
             persistent provider outage.  Pattern observed: 89 codex /
             34 kimi / 13 claude exit-1 events in 3h (#10000-class). *)
          let error_kind =
            let contains needle hay =
              let nl = String.length needle in
              let hl = String.length hay in
              let rec loop i =
                i + nl <= hl
                && (String.sub hay i nl = needle || loop (i + 1))
              in
              loop 0
            in
            if contains "thread " err_str
               && contains " not found" err_str
               && contains "rollout" err_str
            then "transient_codex_rollout"
            else if contains "kimi_cli rejected" err_str then
              "permanent_kimi_rejected"
            else if contains "Network error: codex exited" err_str then
              "network_codex_other"
            else if contains "Network error: claude exited" err_str then
              "network_claude_other"
            else if contains "Network error: gemini exited" err_str then
              "network_gemini_other"
            else "failure"
          in
          Cascade_health_tracker.(
            record_failure global ~provider_key:provider_health_key
              ~error_kind:(error_kind_of_string error_kind)
              ~error_reason:err_str ())));
        (* FSM: Call_err → decide.
           Hard-quota fast-path: a hard quota is permanent for this turn —
           every remaining tier in this cascade (and any cross-cascade
           borrow) will hit the same account-level limit, so retrying
           burns the full OAS turn budget (~60min) for nothing.  Force
           [Exhausted] regardless of [is_last] so the agent loop sees the
           terminal error immediately.  The hard-quota cooldown recorded
           above (line ~1760) keeps this provider deselected for future
           turns; the fast-path only short-circuits the within-turn
           retry. *)
        (match sdk_error_to_cascade_outcome sdk_err with
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
                  cascade_name provider_cfg.model_id class_label
                  (Agent_sdk.Error.to_string sdk_err)
              else
                Log.Misc.info
                  "[cascade-fallback] cascade %s: %s failed (%s%s), trying next"
                  cascade_name provider_cfg.model_id class_label
                  (Agent_sdk.Error.to_string sdk_err);
              Cascade_legacy_runner.record_fallback_event capture ~candidate_cfgs
                ~from_model:provider_cfg.model_id ~to_model:"next"
                ~reason:(class_label ^ Agent_sdk.Error.to_string sdk_err);
              try_cascade ?resume_checkpoint:next_resume rest new_err
            | Cascade_fsm.Exhausted _ ->
              let observation =
                Cascade_legacy_runner.cascade_observation_with_metrics
                  ~cascade_name:error_cascade_name
                  ?strategy:!cascade_strategy_name_ref ~configured_labels
                  ~candidate_cfgs ~selected_model_raw:None ~capture ()
              in
              Cascade_legacy_runner.record_cascade ~keeper_name
                ~cascade_name:error_cascade_name
                ~outcome:`Failure ~observation:(Some observation) ();
              Log.Misc.error "cascade %s exhausted: all tiers failed (last model=%s, error=%s)"
                cascade_name provider_cfg.model_id (Agent_sdk.Error.to_string sdk_err);
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
               ~candidate_cfgs ~selected_model_raw:None ~capture ()
           in
           Cascade_legacy_runner.record_cascade ~keeper_name
             ~cascade_name:error_cascade_name
             ~outcome:`Failure ~observation:(Some observation) ();
           Log.Misc.error "cascade %s: non-cascadable error from %s: %s"
             cascade_name provider_cfg.model_id (Agent_sdk.Error.to_string sdk_err);
           Error sdk_err))
  in
  (* Pluggable strategy + cycle/backoff wrapper (since 0.9.6).

     When no [<name>_strategy] is configured in cascade.json,
     [Cascade_config.resolve_strategy] returns [Cascade_strategy.failover]
     with [max_cycles = 1].  In that case [cycle_loop] invokes
     [try_cascade] exactly once on the original [candidate_cfgs] —
     bit-identical to the pre-strategy behaviour (linear failover). *)
  let* strategy =
    match Cascade_catalog_runtime.resolve_strategy ~name:cascade_name () with
    | Ok strategy -> Ok strategy
    | Error detail ->
        Log.Misc.error "cascade %s: %s" cascade_name detail;
        Error (cascade_catalog_error_to_sdk_error detail)
  in
  let strategy_name = Cascade_strategy.kind_to_string strategy.kind in
  let () = cascade_strategy_name_ref := Some strategy_name in
  let* ollama_max =
    match
      Cascade_catalog_runtime.resolve_ollama_max_concurrent ~name:cascade_name ()
    with
    | Ok value -> Ok value
    | Error detail ->
        Log.Misc.error "cascade %s: %s" cascade_name detail;
        Error (cascade_catalog_error_to_sdk_error detail)
  in
  let* cli_max =
    match Cascade_catalog_runtime.resolve_cli_max_concurrent ~name:cascade_name () with
    | Ok value -> Ok value
    | Error detail ->
        Log.Misc.error "cascade %s: %s" cascade_name detail;
        Error (cascade_catalog_error_to_sdk_error detail)
  in
  let candidate_base_urls =
    List.map (fun (c : Llm_provider.Provider_config.t) -> c.base_url) candidate_cfgs
  in
  (* CLI providers have an empty [base_url]. Map them to a stable
     per-kind sentinel so the strategy's capacity probe and the
     client-capacity registry share the same lookup key. Delegates
     to the OAS SSOT {!Provider_kind.is_subprocess_cli}: any new CLI
     kind added to OAS (e.g. future Codex variants) is picked up
     automatically without touching this site. Sentinel format:
     ["cli:" ^ canonical-lowercase-name], matching
     {!Provider_kind.to_string}. *)
  let cli_sentinel_of_kind kind =
    if Llm_provider.Provider_config.is_subprocess_cli kind then
      Some ("cli:" ^ Llm_provider.Provider_config.string_of_provider_kind kind)
    else
      None
  in
  let capacity_key_of (c : Llm_provider.Provider_config.t) =
    if c.base_url <> "" then c.base_url
    else
      match cli_sentinel_of_kind c.kind with
      | Some s -> s
      | None -> ""
  in
  let candidate_capacity_keys = List.map capacity_key_of candidate_cfgs in
  (match ollama_max with
   | None ->
     Cascade_client_capacity.auto_register_for_candidates
       ~base_urls:candidate_base_urls
   | Some n ->
     Cascade_client_capacity.auto_register_ollama_with_override
       ~base_urls:candidate_base_urls ~max_concurrent:n);
  (* Refresh ollama [/api/ps] cache for any candidate that looks
     like ollama and whose cache entry has expired.  Failures are
     swallowed inside [Cascade_ollama_probe.try_probe] so a flaky
     probe never breaks the cascade — it just denies the cache
     optimisation for this attempt. *)
  Cascade_ollama_probe.refresh_many ~sw ~net candidate_base_urls;
  (match cli_max with
   | None ->
     Cascade_client_capacity.auto_register_cli_for_candidates
       ~capacity_keys:candidate_capacity_keys
   | Some n ->
     Cascade_client_capacity.auto_register_cli_with_override
       ~capacity_keys:candidate_capacity_keys ~max_concurrent:n);
  let adapter : Llm_provider.Provider_config.t Cascade_strategy.adapter = {
    health_key = Provider_adapter.provider_health_key_of_config;
    capacity_key = capacity_key_of;
    weight = (fun _ -> 1);
  } in
  let signal_ctx : Cascade_strategy.signal_ctx = {
    health = Cascade_health_tracker.global;
    capacity = (fun url ->
      match Cascade_throttle.capacity url with
      | Some _ as v -> v
      | None ->
        match Cascade_ollama_probe.cached_capacity url with
        | Some _ as v -> v
        | None -> Cascade_client_capacity.capacity url);
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
        ~candidate_cfgs ~selected_model_raw:None ~capture ()
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
      candidates_in = List.length candidate_cfgs;
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
        ~adapter ~ctx:signal_ctx ~cycle:n candidate_cfgs
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
end
