(** Cascade_metrics — Prometheus emit helpers for cascade routing observability. *)

val on_decision : cascade_name:string -> decision_label:string -> unit
val on_fallback : cascade_name:string -> reason:string -> unit
val on_exhausted : cascade_name:string -> unit
val on_phase_override : phase:string -> from_cascade:string -> to_cascade:string -> unit

val on_profile_discovery : path:string -> unit
(** Tick the profile discovery counter.  [path] must be one of
    [declarative], [legacy_after_decl_error], [legacy_no_decl].
    See [cascade_catalog_runtime.ml] [discover_profile_names]. *)

val on_declarative_parse_error : unit -> unit
(** Tick the declarative parse error counter once per discovery call
    that returned [Error _] from the declarative adapter.  The
    individual error bodies are surfaced via WARN logs at the call
    site. *)

val on_parallel_validation : result:string -> unit
(** Tick the parallel-validation counter for one [validate_path_result]
    invocation.  [result] must be one of [ok], [mismatch],
    [adapter_error], [no_decl]. *)

val on_toml_read_race : unit -> unit
(** Tick the TOML read-race counter once per [load_toml_in_memory]
    call where the cascade.toml mtime drifted between the pre-stat
    and post-stat samples, or the file vanished between samples.
    The loader still returns fresh content but skips the cache
    update so the next call re-converges. *)

val on_serving_last_known_good : reason:string -> unit
(** Tick the serving-last-known-good counter for one [inspect_active]
    invocation that returned [Serving_last_known_good].  [reason] must
    be one of [path_unresolved], [validation_failed],
    [stale_rejection_cached]. *)

val on_degraded_recovery : unit -> unit
(** Tick once per [inspect_active] call that transitions FROM a
    degraded state (either [Serving_last_known_good] from iter 5 or
    [Validated_with_rejections] from iter 11) back to [Validated]
    (operator fixed the cascade.toml fault).  Originally named
    [on_lkg_recovery] in iter 5 when only the LKG case existed;
    renamed in iter 16 after iter 11 broadened the
    [prev_was_failing] detection to include partial-rejection
    recovery. *)

val on_profile_candidate_drop : cascade:string -> reason:string -> unit
(** Tick the per-cascade candidate drop counter at [validate_profile_static]
    when [Cascade_config.parse_weighted_entry_diag] rejects an entry.
    [reason] must be one of [unregistered_scheme], [unavailable_scheme],
    [invalid_syntax]. *)

val on_resolve_provider_leak : cascade:string -> leak_count:int -> unit
(** Tick the resolve-leak counter at [resolve_named_providers] when
    the returned Provider_config.t list contains entries not present
    in the parsed declared profile.  Bumps by [leak_count] (number of
    leaked entries observed in this single resolve call); a [leak_count]
    of zero is a no-op so callers can call unconditionally. *)

val on_route_config_error : error_type:string -> count:int -> unit
(** Tick the route schema-error counter at [validate_path_result] for
    each rejection class folded into [top_errors].  [error_type] must
    be one of [missing_target_profile] (a [\[routes\]] entry points
    at a profile that doesn't exist) or [unknown_route_key] (a
    [\[routes\]] key isn't in the known_route_keys allowlist —
    typo or deprecated key).  Bumps by [count] (number of errors
    of that type in this single validate call); a [count] of zero
    is a no-op so callers can call unconditionally. *)

val on_resolve_failure : cascade:string -> reason:string -> unit
(** Tick the resolve-failure counter for one [resolve_named_providers]
    or [resolve_named_providers_strict] invocation that returned
    [Error _].  [reason] must be one of [lookup_failed],
    [provider_filter_rejected], [no_callable_providers].  [cascade]
    uses the normalized cascade name when available, or the raw
    cascade_name argument when normalization itself failed
    ([lookup_failed] arm). *)

val on_validated_with_rejections : reason:string -> unit
(** Tick the validated-with-rejections counter for one [inspect_active]
    invocation that returned [Validated_with_rejections].  [reason]
    must be one of [fresh_partial_rejection] (validate_path_result
    newly produced a partial rejection on this call) or
    [stale_partial_rejection_cached] (same-mtime cache replay of a
    previously-cached partial rejection). *)

val on_provider_filter_widening : cascade:string -> unit
(** Tick the provider-filter widening counter for one
    [apply_provider_filter] (non-strict) invocation whose filter
    matched no provider in the declared set, causing the function
    to fall back to the unfiltered list.  A non-zero rate signals
    the operator-supplied filter is being silently widened with
    security / budget / SLA implications. *)

val on_auto_expansion_fanout : cascade:string -> fanout:int -> unit
(** Tick the [provider:auto] fan-out counter at
    [expand_weighted_entries] by [fanout] (= output_count -
    input_count).  [fanout=0] is a documented no-op so callers
    invoke unconditionally.  A [rate()] tracks how many extra
    candidates per cascade per second are synthesized by auto
    expansion. *)

val on_ordering_health_widening : cascade:string -> unit
(** Tick the ordering-step health-widening counter at
    [order_weighted_entries] when [Cascade_health_tracker] has cooled
    every provider (active = []) and the function falls back to the
    unfiltered [entries] list.  A non-zero rate signals the health
    tracker judged every provider in this cascade unhealthy yet
    keeper turns continue to route — either the health tracker is
    wrong or the cascade should fail closed. *)

val on_provider_cooldown : provider:string -> reason:string -> unit
(** Tick the per-provider cooldown-entry counter at
    [Cascade_health_tracker.record] when a fresh cooldown_until is
    set.  [reason] must be one of [failure_threshold],
    [soft_rate_limit], [hard_quota], [terminal_failure].  Distinct
    from the existing [keeper_provider_block_duration_sec]
    histogram, which captures duration distribution but not entry
    rate or reason. *)

val on_strategy_starvation_guard : cascade:string -> strategy:string -> unit
(** Tick the strategy-starvation-guard counter when
    [Cascade_strategy.order_candidates] falls through with the
    pre-capacity-filter candidate list because every candidate
    reported capacity=0.  [strategy] must be one of
    [circuit_breaker_cycling] or [priority_tier] (the only two
    branches with this fail-open). *)

val on_sticky_drift : cascade:string -> unit
(** Tick the sticky-drift counter at [Cascade_strategy.sticky_order]
    when a pinned provider is no longer in the candidate list
    (cascade.toml reload, provider deprecation, registry shift)
    and the strategy silently falls back to plain Failover.  Ticks
    only on the drift case, not on normal hit / miss-no-pin paths. *)

val on_sticky_expiry : cascade:string -> unit
(** Tick the sticky-expiry counter at [Cascade_state.lookup_sticky]
    when an entry exists for [(keeper, cascade)] but its TTL has
    expired ([now >= entry.expires_at]).  Distinct from
    [on_sticky_drift] (candidate-list invalidation): this signals
    TTL is too short for the actual keeper request cadence and
    operators should consider raising it. *)

val on_default_label_fallback : cascade:string -> reason:string -> unit
(** Tick the default-label-fallback counter at
    [Cascade_runtime.default_model_strings] when label resolution
    falls back to the hardcoded local default.  [reason] must be one
    of [no_execution_labels] (no execution lane configured at all)
    or [local_cascade_no_local] (local-only cascade with no local
    candidate labels). *)

val on_max_context_fallback : site:string -> unit
(** Tick the max-context fallback counter when [Cascade_runtime]
    resolves [fallback_context_window] instead of a configured
    value.  [site] must be one of [label_no_provider_name],
    [label_unregistered_scheme], [primary_no_available],
    [cascade_max_no_available]. *)

val on_discovered_context_below_floor : unit -> unit
(** Tick the discovered-context floor-violation counter at
    [Cascade_runtime.effective_discovered_ctx] when a per-label
    discovered context_window is below [context_floor] (4_096) and
    the function falls back to the static registry value.  A
    non-zero rate signals a discovery-API misbehavior for at least
    one provider. *)

val on_context_capability_drift : provider:string -> unit
(** Tick the context-capability-drift counter at
    [Cascade_runtime.static_context_of_entry] when the provider
    registry [max_context] disagrees with the capability table's
    [max_context_tokens] (caps_ctx > entry.max_context).  Signals
    operator updated one of two ground truths and forgot the
    other. *)

val on_llama_model_not_discovered : unit -> unit
(** Tick the llama-model-not-discovered counter at
    [Cascade_config.resolve_label_context] when the requested
    llama model_id is not found by
    [Llm_provider.Discovery.context_for_model] and the function
    falls back to the round-robin "auto" endpoint.  A non-zero rate
    means a cascade.toml [llama:specific-model] entry is silently
    routing to whatever endpoint round-robin lands on. *)

val on_route_resolve_fallback : reason:string -> unit
(** Tick the runtime route-resolution fallback counter at
    [Cascade_routes.cascade_name_for_use] when a configured route
    target cannot be honored.  [reason] must be one of
    [catalog_unvalidated] (no validated catalog names available)
    or [target_not_in_catalog] (declared target missing from the
    catalog).  Distinct from iter-9 [route_config_error] which
    ticks during catalog validation. *)

val on_deprecated_profile_name_filter : name:string -> unit
(** Tick the deprecated-profile-name filter counter at the three
    call sites of [Cascade_config_loader.is_deprecated_logical_profile_name].
    [name] is the deprecated profile name itself (the closed set is
    bounded at ~28 names so cardinality stays safe).  Doubles as a
    migration tracker — when the counter stays at zero for a
    given name across deploys, that name can be safely removed
    from [deprecated_logical_profile_names]. *)

val on_capability_mismatch : count:int -> unit
(** Tick the capability-mismatch counter at
    [Cascade_config_loader.load_catalog] when
    [detect_capability_mismatches] returns a non-empty list.
    Bumped by [count] so a deploy that introduces N broken edges
    spikes proportionally; [count=0] is a no-op so callers invoke
    unconditionally.  Counter complement to the existing
    [metric_cascade_fallback_cycle_detected_total] (already covers
    cycles); together they observe the two RFC-0055/0058 fallback
    graph invariants. *)

val on_route_binding_dropped : reason:string -> unit
(** Tick the route-binding-dropped counter at
    [Cascade_routes.route_bindings_from_json] when an entry in the
    [routes] table is silently dropped.  [reason] must be one of
    [invalid_value] (neither legacy-string nor declarative-table
    encoding produced a target) or [empty_key_or_target] (target
    or key trimmed to empty string). *)

val on_weighted_item_dropped : reason:string -> unit
(** Tick the weighted-item-dropped counter at
    [Cascade_config_loader.parse_weighted_item] when an entry in
    the legacy [<name>_models] list is silently dropped.
    [reason] must be one of [missing_or_empty_model] or
    [invalid_value_type].  Also doubles as an RFC-0066 Phase 4
    migration tracker — 5-layer cascade.toml never hits this
    path, so non-zero rate flags legacy fixtures. *)
