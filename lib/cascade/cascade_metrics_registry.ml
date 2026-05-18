(** Registration table for cascade Prometheus counters. *)

let all_cascade_counters : (string * string) list =
  [ "masc_cascade_decisions_total", "masc_cascade_decisions_total"
  ; "masc_cascade_fallbacks_total", "masc_cascade_fallbacks_total"
  ; ( "masc_cascade_providers_exhausted_total"
    , "masc_cascade_providers_exhausted_total" )
  ; ( "masc_cascade_routing_phase_overrides_total"
    , "masc_cascade_routing_phase_overrides_total" )
  ; ( "masc_cascade_profile_discovery_total"
    , "masc_cascade_profile_discovery_total" )
  ; ( "masc_cascade_declarative_parse_errors_total"
    , "masc_cascade_declarative_parse_errors_total" )
  ; ( "masc_cascade_parallel_validation_total"
    , "masc_cascade_parallel_validation_total" )
  ; ( "masc_cascade_toml_read_race_total"
    , "masc_cascade_toml_read_race_total" )
  ; ( "masc_cascade_serving_last_known_good_total"
    , "Total inspect_active calls that returned Serving_last_known_good. \
       Labels: reason (path_unresolved | validation_failed | \
       stale_rejection_cached). Operator action: investigate cascade.toml \
       load fault; the keeper is serving a stale cached snapshot." )
  ; ( "masc_cascade_degraded_recovery_total"
    , "Total inspect_active calls that transitioned from a degraded \
       state (LKG or Validated_with_rejections) back to Validated. \
       Non-zero rate confirms operator fixes are taking effect." )
  ; ( "masc_cascade_profile_candidate_drop_total"
    , "Total weighted entries dropped at [validate_profile_static] \
       because [parse_weighted_entry_diag] rejected them. Labels: \
       cascade, reason (unregistered_scheme | unavailable_scheme | \
       invalid_syntax). [unavailable_scheme] is the most common \
       operator-actionable cause (missing API credential / disabled \
       runtime lane)." )
  ; ( "masc_cascade_resolve_provider_leak_total"
    , "Total provider entries returned by [resolve_named_providers] \
       that are NOT in the parsed declared profile (alias expansion, \
       provider_filter fallback widening, or genuine configuration \
       drift). Bumped by leak_count per resolve call (delta \
       semantics). Labels: cascade." )
  ; "masc_cascade_route_config_error_total", "masc_cascade_route_config_error_total"
  ; ( "masc_cascade_resolve_failure_total"
    , "Total resolve_named_providers[_strict[_with_secondary_resolver]] \
       invocations that returned Error. Labels: cascade, reason \
       (lookup_failed | provider_filter_rejected | no_callable_providers). \
       Operator action: cascade.toml typo or provider unavailable." )
  ; ( "masc_cascade_validated_with_rejections_total"
    , "masc_cascade_validated_with_rejections_total" )
  ; ( "masc_cascade_provider_filter_widening_total"
    , "Total apply_provider_filter (non-strict) invocations where the \
       operator-supplied filter matched no provider and the function \
       silently fell back to the unfiltered list. Security / budget / \
       SLA implication: the filter intent is being ignored. Operator \
       action: switch to apply_provider_filter_strict or fix the \
       cascade.toml provider list." )
  ; ( "masc_cascade_auto_expansion_fanout_total"
    , "masc_cascade_auto_expansion_fanout_total" )
  ; ( "masc_cascade_ordering_health_widening_total"
    , "masc_cascade_ordering_health_widening_total" )
  ; ( "masc_cascade_provider_cooldown_total"
    , "Total fresh cooldown entries set at [Cascade_health_tracker]. \
       Labels: provider, reason (failure_threshold | soft_rate_limit \
       | hard_quota | terminal_failure). Counter complement to the \
       existing [keeper_provider_block_duration_sec] histogram \
       (duration distribution, this is entry rate by cause)." )
  ; ( "masc_cascade_strategy_starvation_guard_total"
    , "masc_cascade_strategy_starvation_guard_total" )
  ; ( "masc_cascade_default_label_fallback_total"
    , "masc_cascade_default_label_fallback_total" )
  ; ( "masc_cascade_max_context_fallback_total"
    , "Total context-window resolutions falling back to \
       [fallback_context_window] (128_000). Labels: site \
       (label_no_provider_name | label_unregistered_scheme | \
       primary_no_available | cascade_max_no_available). Keeper \
       turn runs at the fallback window instead of any configured \
       value - operators querying for long-context capability \
       should check non-zero rates per site." )
  ; ( "masc_cascade_discovered_context_below_floor_total"
    , "masc_cascade_discovered_context_below_floor_total" )
  ; ( "masc_cascade_context_capability_drift_total"
    , "masc_cascade_context_capability_drift_total" )
  ; ( "masc_cascade_llama_model_not_discovered_total"
    , "masc_cascade_llama_model_not_discovered_total" )
  ; ( "masc_cascade_route_resolve_fallback_total"
    , "Total cascade_name_for_use invocations where the declared route \
       target could not be honored at runtime. Labels: reason \
       (catalog_unvalidated | target_not_in_catalog). Operator action: \
       fix the [routes] table in cascade.toml." )
  ; ( "masc_cascade_deprecated_profile_name_filter_total"
    , "Total profile names filtered by \
       [is_deprecated_logical_profile_name] across 3 catalog-build \
       call sites. Label: name (one of ~28 closed deprecated names). \
       Doubles as RFC-0066 Phase 4 migration tracker: per-name rate \
       stays at zero across deploys -> safe to drop from \
       [deprecated_logical_profile_names]." )
  ; ( "masc_cascade_capability_mismatch_total"
    , "Total catalog validation passes that detected at least one \
       RFC-0055 capability subset violation on a fallback_cascade edge. \
       Bumped by the number of mismatches per call (delta semantics). \
       Operator action: align source profile capability requirements \
       with the fallback target." )
  ; ( "masc_cascade_route_binding_dropped_total"
    , "masc_cascade_route_binding_dropped_total" )
  ; ( "masc_cascade_weighted_item_dropped_total"
    , "masc_cascade_weighted_item_dropped_total" )
  ; ( "masc_cascade_resolve_live_fallback_total"
    , "masc_cascade_resolve_live_fallback_total" )
  ; ( "masc_cascade_fallback_hint_invalid_total"
    , "masc_cascade_fallback_hint_invalid_total" )
  ; ( "masc_cascade_runtime_mcp_legacy_strip_total"
    , "Total runtime_mcp_policy_for_provider invocations where a \
       provider requires per-keeper bridging but the caller did not \
       supply agent_name; auth-bearing headers are silently stripped \
       and runtime MCP tools run unauthenticated. Caller-contract \
       fault, not config - fix the calling code path to thread \
       agent_name through." )
  ; ( "masc_cascade_partial_eio_context_total"
    , "Total [refresh_local_discovery_if_possible] calls where only \
       one of [Eio.Switch.t] / [Eio.Net.t] was available (caller \
       forgot [Eio_context.set_switch] / [set_net]). The existing \
       WARN-once dedups log noise; this counter ticks every hit so \
       a chronic caller-side regression stays observable after the \
       WARN is suppressed. Operator action: thread Eio context to \
       the failing call site (RFC-0037 section 4.3)." )
  ; ( "masc_cascade_discovery_refresh_exception_total"
    , "Total refresh_local_discovery_if_possible calls that caught a \
       non-cancellation exception from refresh_llama_endpoints. The \
       exception is swallowed and the function returns false; this \
       counter makes the swallow rate alertable." )
  ; ( "masc_cascade_profile_registration_failure_total"
    , "Total declarative catalog loads where \
       [register_declared_profiles_from_json] returned Error. \
       Catalog continues loading without the declared profiles, so \
       downstream [resolve_required_capabilities] returns None for \
       these names and capability filtering falls back to defaults. \
       Pair with iter 6 / iter 14 [profile_candidate_drop] which \
       surfaces the downstream effect of these registration gaps." )
  ; ( "masc_cascade_invariant_violation_total"
    , "Total Cascade_fsm contract violations (should-be-unreachable \
       defensive arms). MUST be zero in steady state. Any non-zero \
       rate is a guaranteed FSM bug - not a tunable; alert immediately \
       and investigate the FSM transition that exposed an Accept in \
       Accept_rejected branch." )
  ; ( "masc_cascade_metrics_eviction_total"
    , "masc_cascade_metrics_eviction_total" )
  ; "masc_cascade_max_tokens_clamped_total", "masc_cascade_max_tokens_clamped_total"
  ; "masc_cascade_audit_failure_total", "masc_cascade_audit_failure_total"
  ; "masc_cascade_local_context_clamped_total", "masc_cascade_local_context_clamped_total"
  ]
