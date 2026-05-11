(** Cascade_metrics — Prometheus emit helpers for cascade routing observability.

    Mirrors TLA+ invariants in runtime telemetry.

    Metric ownership follows RFC-0043: this module owns the cascade metric
    name constants. [Prometheus.ml]'s [register_all()] still mirrors them
    for /metrics endpoint registration (transitional); the SSOT remains here.

    @since 0.192.0 *)

let metric_decisions = "masc_cascade_decisions_total"
let metric_fallbacks = "masc_cascade_fallbacks_total"
let metric_providers_exhausted = "masc_cascade_providers_exhausted_total"
let metric_routing_phase_overrides = "masc_cascade_routing_phase_overrides_total"

(* RFC-0066 Phase 4 migration observability: which path discovered the
   profile names — the declarative 5-layer parser ([Some (Ok _)]) or
   the legacy [<name>_models] JSON-shape scan ([Some (Error _)] or
   [None]).  Operators use [path="legacy_*"] non-zero counters as the
   signal that fixture migration is incomplete (legacy_no_decl) or that
   the live [cascade.toml] is malformed (legacy_after_decl_error). *)
let metric_profile_discovery = "masc_cascade_profile_discovery_total"

(* Declarative parser ran but returned errors.  Counter ticks per
   discovery call, not per error within a call — the individual errors
   are surfaced via WARN logs.  A non-zero rate here means the live
   cascade.toml is producing adapter errors even though the loader
   keeps serving (currently via legacy fallback). *)
let metric_declarative_parse_errors = "masc_cascade_declarative_parse_errors_total"

(* Parallel declarative validation (RFC-0058 Phase 3) cross-checks the
   JSON-shape discovery path against the typed declarative parser
   inside [validate_path_result].  The previous behavior was WARN-only
   on mismatch — operators had no Prometheus signal to alert on, and
   "INFO parallel validation OK" was indistinguishable from "no
   validation ran".  Counter labels:
   - "ok"            — both paths agreed (steady state)
   - "mismatch"      — both paths produced lists but disagreed on the
                       set (spurious mismatches were possible before
                       [decl_snapshot_profile_names] gained sort_uniq;
                       a non-zero rate after that fix is a real
                       drift signal that warrants operator attention)
   - "adapter_error" — declarative parser returned errors during
                       parallel validation (independent of the
                       [profile_discovery] path observed in
                       [discover_profile_names])
   - "no_decl"       — declarative parser produced no result; expected
                       for pre-RFC-0058 fixture TOML *)
let metric_parallel_validation = "masc_cascade_parallel_validation_total"

let on_decision ~cascade_name ~decision_label =
  Prometheus.inc_counter metric_decisions
    ~labels:[ ("decision", decision_label); ("cascade", cascade_name) ]
    ()

let on_fallback ~cascade_name ~reason =
  Prometheus.inc_counter metric_fallbacks
    ~labels:[ ("reason", reason); ("cascade", cascade_name) ]
    ()

let on_exhausted ~cascade_name =
  Prometheus.inc_counter metric_providers_exhausted
    ~labels:[ ("cascade", cascade_name) ]
    ()

let on_phase_override ~phase ~from_cascade ~to_cascade =
  Prometheus.inc_counter metric_routing_phase_overrides
    ~labels:
      [ ("phase", phase)
      ; ("from_cascade", from_cascade)
      ; ("to_cascade", to_cascade)
      ]
    ()

(* [path] is one of:
   - "declarative" — 5-layer parser succeeded (the steady-state path)
   - "legacy_after_decl_error" — declarative parser returned errors and
     the loader fell through to the legacy [<name>_models] scan
   - "legacy_no_decl" — declarative parser produced no result (likely
     a pre-RFC-0058 fixture TOML) *)
let on_profile_discovery ~path =
  Prometheus.inc_counter metric_profile_discovery
    ~labels:[ ("path", path) ]
    ()

let on_declarative_parse_error () =
  Prometheus.inc_counter metric_declarative_parse_errors ()

(* [result] is one of "ok" | "mismatch" | "adapter_error" | "no_decl". *)
let on_parallel_validation ~result =
  Prometheus.inc_counter metric_parallel_validation
    ~labels:[ ("result", result) ]
    ()

(* Ticks once per [load_toml_in_memory] call that detected the
   cascade.toml mtime drifted between the pre-stat and post-stat
   samples (atomic rename / writer fsync race), or the file vanished
   between samples.  A non-zero rate in steady state suggests a tight
   writer loop or a deploy pipeline that touches the file multiple
   times during release; a transient tick during operator-driven
   reloads is expected. *)
let metric_toml_read_race = "masc_cascade_toml_read_race_total"

let on_toml_read_race () =
  Prometheus.inc_counter metric_toml_read_race ()

(* Ticks once per [inspect_active] call that returned
   [Serving_last_known_good].  This state means the runtime cannot
   validate the current cascade.toml but is still serving the last
   snapshot that did validate; without a counter, operators had no way
   to know the catalog had drifted into a degraded state.  Labels:
   - "path_unresolved" — the config path itself failed to resolve
                          (env / .masc/config layout broken).  Severe.
   - "validation_failed" — fresh validation produced [Error _] but a
                            cached snapshot was available.  Severe.
   - "stale_rejection_cached" — the rejection cached on the previous
                                  call matches the current source-path
                                  mtime, so we replay the LKG outcome
                                  without re-validating.  Steady-state
                                  while the operator hasn't fixed the
                                  fault — log noise must stay low here.
*)
let metric_serving_last_known_good = "masc_cascade_serving_last_known_good_total"

let on_serving_last_known_good ~reason =
  Prometheus.inc_counter metric_serving_last_known_good
    ~labels:[ ("reason", reason) ]
    ()

(* Ticks once per [inspect_active] call that transitions FROM a
   non-empty [rejected_update] back TO [None] (i.e. operator fixed
   the fault and the next validation passed clean).  Distinguishes
   a real recovery from steady-state validated calls.

   The detection condition ([prev_was_failing] boolean over
   [rejected_update]) catches BOTH the LKG -> Validated transition
   (iter 5) and the Validated_with_rejections -> Validated
   transition (iter 11); the metric name and helper were originally
   "lkg_recovery" but their actual semantics are "degraded -> clean
   recovery".  Renamed to [degraded_recovery] for honesty (iter 16). *)
let metric_degraded_recovery = "masc_cascade_degraded_recovery_total"

let on_degraded_recovery () =
  Prometheus.inc_counter metric_degraded_recovery ()

(* Profile-validation step rejects individual candidates with one of
   three typed reasons from [Cascade_config.parse_weighted_entry_diag].
   Previously the reason was surfaced only in the profile_rejection
   error message — operators had no machine-readable signal to alert
   on (e.g. a missing credential dropping a whole cascade arm).
   Pair to [Provider_tool_support.cascade_filter_rejection_metric]
   (#10474), which observes the rejection happening one step later
   in the pipeline (filter stage, after parsing succeeded).

   Cardinality: cascades (~10) × reasons (3) = ~30 series.

   Labels:
   - "unregistered_scheme" — provider scheme not in the runtime
                              registry (typo or removed adapter)
   - "unavailable_scheme"  — registered but missing credential or
                              runtime lane disabled (the most common
                              operator-actionable signal)
   - "invalid_syntax"      — entry string couldn't be parsed at all *)
let metric_profile_candidate_drop = "masc_cascade_profile_candidate_drop_total"

let on_profile_candidate_drop ~cascade ~reason =
  Prometheus.inc_counter metric_profile_candidate_drop
    ~labels:[ ("cascade", cascade); ("reason", reason) ]
    ()

(* [resolve_named_providers] compares the [Provider_config.t] list it
   actually returns against the canonical labels parsed from the
   declared profile.  Mismatch ("leak") means the resolver synthesized
   a provider that was not literally declared in cascade.toml — most
   commonly via alias expansion ([codex_cli:auto] -> a concrete model)
   or provider_filter fallback widening, but in pathological cases a
   genuine configuration drift where keeper turns route to a
   provider the operator never approved.

   Previously this was WARN-log only at the call site; operators had
   no way to alert on leak rate without scraping logs.  Bumping the
   counter by the number of leaked entries (not just calls) means a
   dashboard can show "leak provider-hits per second per cascade",
   distinguishing a single chronic alias from a sudden cascade-wide
   widening.

   Cardinality: cascades (~10) = ~10 series.  Provider-kind label
   intentionally NOT added — the WARN line already enumerates the
   leaked provider strings, and adding kind labels here would force
   string parsing of the leaked entries to extract the kind. *)
let metric_resolve_provider_leak = "masc_cascade_resolve_provider_leak_total"

let on_resolve_provider_leak ~cascade ~leak_count =
  if leak_count > 0 then
    Prometheus.inc_counter metric_resolve_provider_leak
      ~labels:[ ("cascade", cascade) ]
      ~delta:(float_of_int leak_count)
      ()

(* [validate_path_result] folds two schema-error sources into the
   single [top_errors] list before turning the validation into a
   rejection: missing route targets (a [\[routes\]] entry points at a
   profile that doesn't exist) and unknown route keys (a [\[routes\]]
   key isn't in the known_route_keys allowlist — typo or deprecated
   key).  Iter 5's [serving_last_known_good_total{reason}] tells
   operators that validation failed but does not split the cause; the
   actual error reason was only present in the rejection error
   strings.  These two are by far the most common operator-actionable
   schema mistakes; split them out so dashboards can show typo-rate
   vs missing-profile-rate as separate time series.

   Bumped by [count] per validate_path_result invocation rather than
   +1 per call (same shape as resolve_provider_leak): a single typo
   commit can land multiple missing targets at once, and dashboards
   benefit from seeing the magnitude.

   Cardinality: 2 (error_type values).  No cascade name label —
   validate_path_result runs against a single cascade.toml, and
   adding the raw route key as a label would explode cardinality
   on operator typos.  Detail belongs in the rejection error string,
   not the metric. *)
let metric_route_config_error = "masc_cascade_route_config_error_total"

let on_route_config_error ~error_type ~count =
  if count > 0 then
    Prometheus.inc_counter metric_route_config_error
      ~labels:[ ("error_type", error_type) ]
      ~delta:(float_of_int count)
      ()

(* [resolve_named_providers] and [resolve_named_providers_strict] each
   have three Error return points that previously emitted neither
   counter nor log:

     lookup_failed             — [lookup_active_profile] returned Error
                                  (snapshot unavailable OR unknown
                                  cascade name in snapshot)
     provider_filter_rejected  — strict variant only: provider_filter
                                  rejected the declared set
     no_callable_providers     — final filter step left the resolved
                                  list empty

   Iter 7's [on_resolve_provider_leak] observes the OK arm only;
   these Error arms were the symmetric blind spot.  When keeper turns
   experience a sudden spike of "cascade X failed at resolve", the
   existing [masc_cascade_fallbacks_total] tells operators THAT
   fallback fired but not WHY the primary failed — that detail used
   to live only in the WARN log line at the call site (and in some
   arms not even that).

   Cardinality: cascades (~10) × reasons (3) = ~30 series.  Cascade
   name uses the normalized form when available; the lookup_failed
   arm uses the raw [cascade_name] argument because normalization
   itself failed. *)
let metric_resolve_failure = "masc_cascade_resolve_failure_total"

let on_resolve_failure ~cascade ~reason =
  Prometheus.inc_counter metric_resolve_failure
    ~labels:[ ("cascade", cascade); ("reason", reason) ]
    ()

(* [inspect_active] can settle in three Ok-but-degraded states:
   - [Serving_last_known_good]  — fresh validation failed entirely;
                                   iter 5 owns this metric.
   - [Validated_with_rejections] — fresh validation succeeded but
                                   PART of the cascade.toml was
                                   rejected (e.g. a newly added
                                   profile fails its own validation
                                   while the rest of the catalog
                                   stays valid).  Keeper turns still
                                   route, but the rejected subset is
                                   silently absent — the operator
                                   who added the profile may not
                                   realize it didn't take effect.

   Reasons:
   - "fresh_partial_rejection"   — validate_path_result newly
                                    produced [Ok { rejected_update =
                                    Some _ }] this call (L1059).
   - "stale_partial_rejection_cached" — same-mtime cache replay
                                         of a previously-cached
                                         partial rejection (L1002).
   The split mirrors the LKG counter's
   ["validation_failed" / "stale_rejection_cached"] pair so dashboards
   can tell entry from steady-state. *)
let metric_validated_with_rejections = "masc_cascade_validated_with_rejections_total"

let on_validated_with_rejections ~reason =
  Prometheus.inc_counter metric_validated_with_rejections
    ~labels:[ ("reason", reason) ]
    ()

(* [apply_provider_filter] (non-strict) is a fail-OPEN filter: when
   the operator-supplied [provider_filter] matches no provider in the
   declared set, the function falls back to the UNFILTERED list
   instead of rejecting.  The strict variant
   [apply_provider_filter_strict] is fail-CLOSED (returns Error,
   counted by [on_resolve_failure ~reason:"provider_filter_rejected"]
   in iter 10), but the non-strict path was silent except for a WARN
   line at the call site.

   A non-zero rate here means the operator's filter expressed an
   intent ("use only anthropic for this cascade") that the runtime
   silently widened to "use any provider in this cascade", with
   security / budget / SLA implications.  Different signal from
   iter 7's [on_resolve_provider_leak] (which compares
   declared-vs-returned, not filter-vs-result).

   Cardinality: cascades (~10) = ~10 series. *)
let metric_provider_filter_widening = "masc_cascade_provider_filter_widening_total"

let on_provider_filter_widening ~cascade =
  Prometheus.inc_counter metric_provider_filter_widening
    ~labels:[ ("cascade", cascade) ]
    ()

(* [expand_weighted_entries] fans a single [provider:auto] entry out
   to N concrete candidates via [Cascade_config.expand_auto_models]
   ("glm:auto" -> ["glm:glm-5.1"; "glm:glm-5-turbo"; ...]).  The
   per-cascade fan-out amount was silent: operators saw one line in
   cascade.toml but the runtime cascading list was N entries, and a
   change in the registry (new provider added, model deprecated)
   would silently shift the effective candidate count without any
   dashboard signal.

   Bumped by [fanout] = [output_count - input_count] per call so a
   [rate()] tracks "extra candidates synthesized per cascade per
   second".  [fanout = 0] (all plain entries, no auto expansion) is
   a documented no-op so callers can call unconditionally.

   Cardinality: cascades (~10) = ~10 series. *)
let metric_auto_expansion_fanout = "masc_cascade_auto_expansion_fanout_total"

let on_auto_expansion_fanout ~cascade ~fanout =
  if fanout > 0 then
    Prometheus.inc_counter metric_auto_expansion_fanout
      ~labels:[ ("cascade", cascade) ]
      ~delta:(float_of_int fanout)
      ()

(* [order_weighted_entries] is a fail-OPEN ordering step: when the
   [Cascade_health_tracker] has cooled all providers (every weight
   drops to 0 and [active = []]), the function silently falls back
   to the unfiltered [entries] list — same shape as iter 12's
   [provider_filter_widening], one stage later in the pipeline.

   A non-zero rate here means [Cascade_health_tracker] judged every
   provider in this cascade unhealthy, yet keeper turns continue to
   route on the same list as if the health tracker had said nothing.
   That's an emergency signal: either the health tracker is wrong
   (false negatives across the board) or every provider is actually
   down and the cascade should fail closed.

   Cardinality: cascades (~10) = ~10 series. *)
let metric_ordering_health_widening = "masc_cascade_ordering_health_widening_total"

let on_ordering_health_widening ~cascade =
  Prometheus.inc_counter metric_ordering_health_widening
    ~labels:[ ("cascade", cascade) ]
    ()

(* [Cascade_health_tracker.record] has four distinct cooldown-entry
   branches (Failure-threshold, Soft_rate_limited, Hard_quota,
   Terminal_failure) that each set a fresh [cooldown_until].  Until
   iter 20 these only emitted a [keeper_provider_block_duration_sec]
   histogram, so dashboards saw duration distribution but no entry
   rate and no reason attribution.  A spike of "all providers down"
   downstream (iter 18 ordering_health_widening) could be driven by
   any of the four reasons, and operators had no way to distinguish
   "global outage shapes" (hard_quota across providers) from
   "single-provider flap" (failure_threshold on one key).

   The counter ticks ONLY when [new_until > state.cooldown_until],
   matching the same gate that protects the histogram — already-longer
   cooldowns don't re-trigger.

   Cardinality: providers (~10) x reasons (4) = ~40 series. *)
let metric_provider_cooldown = "masc_cascade_provider_cooldown_total"

let on_provider_cooldown ~provider ~reason =
  Prometheus.inc_counter metric_provider_cooldown
    ~labels:[ ("provider", provider); ("reason", reason) ]
    ()

(* Two [Cascade_strategy] ordering branches have a "starvation guard"
   fail-OPEN: when every candidate reports capacity=0 the function
   falls through with the pre-filter candidate list so at least one
   call is attempted (and the upstream real error — rate limit,
   auth — surfaces) instead of silently exhausting the cascade.

   - Circuit_breaker_cycling — [order_candidates] line 608-609
   - Priority_tier           — [priority_tier_order] line 542-543

   The third ordering strategy ([weighted_shuffle]) deliberately
   fails closed and is NOT covered by this counter.

   A non-zero rate signals capacity probes have been judging the
   cascade exhausted; pair with iter-8 probe metrics and iter-20
   provider_cooldown to attribute the cause.

   Cardinality: cascades (~10) x strategies (2) = ~20 series. *)
let metric_strategy_starvation_guard = "masc_cascade_strategy_starvation_guard_total"

let on_strategy_starvation_guard ~cascade ~strategy =
  Prometheus.inc_counter metric_strategy_starvation_guard
    ~labels:[ ("cascade", cascade); ("strategy", strategy) ]
    ()

(* [Cascade_strategy.sticky_order] looks up a per-(keeper, cascade)
   sticky pin via [Cascade_state.lookup_sticky] and three outcomes
   are possible:
     - None        : no pin (first lookup, or TTL expired) — normal
     - Some + hit  : pin still in candidate list — normal stick
     - Some + miss : pin no longer in candidate list — DRIFT
                     (e.g. operator removed the provider from
                     cascade.toml, or a registry reload dropped it)

   The drift arm silently falls back to plain Failover, breaking
   the operator-expressed intent to stick to one provider, with
   only a code comment as evidence.  Counter only ticks on drift
   (not on the normal hit/miss-no-pin paths) so a non-zero rate
   directly maps to "sticky intent broken N times".

   Cardinality: cascades (~10) = ~10 series. *)
let metric_sticky_drift = "masc_cascade_sticky_drift_total"

let on_sticky_drift ~cascade =
  Prometheus.inc_counter metric_sticky_drift
    ~labels:[ ("cascade", cascade) ]
    ()

(* [Cascade_state.lookup_sticky] returns None in two distinct cases
   that were previously indistinguishable to callers:
     - No entry recorded yet (first lookup for this keeper+cascade)
     - Entry recorded but TTL expired (now >= entry.expires_at)

   Only the second is interesting to operators — it's the explicit
   signal that the configured TTL is too short for the actual
   keeper request cadence, breaking the sticky-intent before the
   next turn lands.  iter 23 covers [sticky_drift] (pin invalidated
   by candidate-list change); this counter covers the orthogonal
   case (pin invalidated by TTL).  Both surfaces matter for TTL
   tuning: too-short TTL inflates [sticky_expiry], too-long TTL
   inflates [sticky_drift].

   The no-pin case is NOT counted (normal first lookup, no operator
   signal).

   Cardinality: cascades (~10) = ~10 series. *)
let metric_sticky_expiry = "masc_cascade_sticky_expiry_total"

let on_sticky_expiry ~cascade =
  Prometheus.inc_counter metric_sticky_expiry
    ~labels:[ ("cascade", cascade) ]
    ()

(* [Cascade_runtime.default_model_strings] has two arms that fall
   back to [Provider_adapter.default_local_fallback_label] when the
   normal cascade.toml-derived label resolution can't produce
   anything usable:

     no_execution_labels        — neither
                                  [explicit_llama_model_label_result]
                                  nor [preferred_execution_model_labels]
                                  produced any label.  Operator likely
                                  hasn't configured any execution lane.
     local_cascade_no_local     — cascade is local-only but its
                                  candidate labels contain no local
                                  scheme.  Operator routed local
                                  traffic at a cascade with only
                                  remote providers.

   Both arms silently substitute a single hardcoded
   [default_local_fallback_label].  Until iter 25 the only way to
   notice was to inspect resolved Provider_config lists at the
   dashboard.  Counter ticks here lift the silent fallback to a
   per-cascade rate operators can alert on.

   Cardinality: cascades (~10) x reasons (2) = ~20 series. *)
let metric_default_label_fallback = "masc_cascade_default_label_fallback_total"

let on_default_label_fallback ~cascade ~reason =
  Prometheus.inc_counter metric_default_label_fallback
    ~labels:[ ("cascade", cascade); ("reason", reason) ]
    ()

(* [Cascade_runtime] has four context-window resolution sites that
   silently fall back to the hardcoded [fallback_context_window]
   (128_000) when normal resolution can't produce a value:

     label_no_provider_name      — [max_context_of_label]:
                                    [provider_name_of_label] returned
                                    None (malformed label string)
     label_unregistered_scheme   — [max_context_of_label]:
                                    [Provider_registry.find] returned
                                    None (scheme not registered)
     primary_no_available        — [resolve_primary_max_context]:
                                    no label had an available provider
                                    via [context_if_available]
     cascade_max_no_available    — [resolve_max_cascade_context]:
                                    same condition, in the
                                    cascade-max-context aggregator

   The four sites don't carry a cascade-name context (function
   signatures take label lists only), so the counter labels by
   [site] rather than by cascade — cardinality stays at 4 series
   and operators can alert on the aggregate fallback rate, then
   drill down via log/dashboard.

   Cardinality: 4 series.

   A non-zero rate signals operator-configured context_window is
   not taking effect — either cascade.toml drift, registry
   capability gaps, or all providers unavailable in the cascade. *)
let metric_max_context_fallback = "masc_cascade_max_context_fallback_total"

let on_max_context_fallback ~site =
  Prometheus.inc_counter metric_max_context_fallback
    ~labels:[ ("site", site) ]
    ()

(* [Cascade_runtime.effective_discovered_ctx] applies a
   [context_floor] safety net: when the per-label dynamic-discovery
   API reports a context_window below the floor (4_096 tokens), the
   function silently falls back to [static_ctx] from the registry,
   on the theory that an absurdly small "discovered" value is more
   likely a discovery-API bug or response corruption than a real
   small-context model.

   The fallback is intentional, but its rate had no visibility
   until iter 27.  A non-zero rate signals the discovery API for
   SOME provider is returning suspicious values; pair with iter-8
   probe metrics to attribute the misbehaving provider.

   No label dimensions: the helper takes raw integers, the caller
   carries the label string.  Adding a label here would require
   threading label context through 2+ caller sites and
   [effective_discovered_ctx] is a generic numeric helper that
   shouldn't know about cascade structure.  Aggregate rate is
   sufficient for the alert; operators drill down via logs.

   Cardinality: 1 series. *)
let metric_discovered_context_below_floor =
  "masc_cascade_discovered_context_below_floor_total"

let on_discovered_context_below_floor () =
  Prometheus.inc_counter metric_discovered_context_below_floor ()

(* [Cascade_runtime.static_context_of_entry] has two ground truths
   for a provider context window:
     - [entry.max_context]                       (legacy registry default)
     - [entry.capabilities.max_context_tokens]   (newer capability table)

   When [caps_ctx > entry.max_context] the function silently picks
   [caps_ctx], on the theory that the capability table is newer and
   more accurate.  In practice the inequality means the operator
   updated ONE of the two sources and forgot the other — a drift
   signal that operators should know about so the stale value can
   be brought in sync.

   Cardinality: provider names (~10) = ~10 series. *)
let metric_context_capability_drift =
  "masc_cascade_context_capability_drift_total"

let on_context_capability_drift ~provider =
  Prometheus.inc_counter metric_context_capability_drift
    ~labels:[ ("provider", provider) ]
    ()

(* [Cascade_config.resolve_label_context] has a llama-specific
   fallback: when [Llm_provider.Discovery.context_for_model] cannot
   locate the requested model_id on any registered endpoint, the
   function falls back to the round-robin "auto" endpoint
   ([current_llama_endpoint]).  This breaks operator intent — a
   cascade.toml entry "llama:specific-model" silently routes to
   whatever endpoint round-robin happens to land on instead of the
   specific model.

   Causes:
     - operator referenced a model that hasn't been pulled / loaded
       on any registered endpoint
     - Discovery API hasn't synced yet after a fresh ollama serve
       startup
     - model name typo in cascade.toml

   No label dimensions: function takes a label string but adding
   model_id as a label would produce unbounded cardinality from
   operator typos.  Aggregate rate alerts; drill down via logs.

   Cardinality: 1 series. *)
let metric_llama_model_not_discovered =
  "masc_cascade_llama_model_not_discovered_total"

let on_llama_model_not_discovered () =
  Prometheus.inc_counter metric_llama_model_not_discovered ()

(* [Cascade_routes.cascade_name_for_use] has two fallback arms that
   resolve a route to a hardcoded fallback instead of the
   operator-declared target:

     catalog_unvalidated    — route_target is set but the live
                               catalog has zero validated names
                               (cascade.toml load / validate fault).
                               The runtime resolves anyway via
                               fallback_from_entries.
     target_not_in_catalog  — route_target points at a profile that
                               is not in the validated catalog.
                               Typically a typo or a profile removed
                               from cascade.toml without updating the
                               [routes] table.

   Distinct from iter 9 [route_config_error{error_type}]: that
   counter ticks during [validate_path_result] when the catalog is
   built; this counter ticks during runtime route RESOLUTION when
   [cascade_name_for_use] is called (e.g. on every keeper turn).
   The two windows can disagree: validate_path_result may have
   built a valid catalog (no schema error), but a subsequent
   [cascade_name_for_use] call may still hit the unvalidated arm if
   a downstream caller threads in a stale config_path.

   The third arm (None — no route configured for this use) stays
   silent: normal "operator did not set a route" path.

   Cardinality: 2 reasons = 2 series. *)
let metric_route_resolve_fallback =
  "masc_cascade_route_resolve_fallback_total"

let on_route_resolve_fallback ~reason =
  Prometheus.inc_counter metric_route_resolve_fallback
    ~labels:[ ("reason", reason) ]
    ()

(* [Cascade_config_loader.is_deprecated_logical_profile_name] returns
   true for ~28 legacy profile names (pre-RFC-0058 conventions like
   "default", "keeper_reply", "phase_recovery", etc.).  Three callers
   filter these names out of profile discovery silently:
     - cascade_catalog_runtime.ml L175 (legacy [_models] fallback)
     - cascade_catalog_runtime.ml L190 (declarative path filter)
     - cascade_config_loader.ml L576 (builder validation)

   When an operator references one of these names in a current
   cascade.toml (typo, copy-paste from old docs, surviving fixture),
   the profile is silently dropped from the catalog.  Downstream
   route resolution then fails with the iter 30
   [route_resolve_fallback] counter, but the root cause (deprecated
   name filtered) is invisible.

   The label is the deprecated name itself.  The set is closed
   (~28 names), so cardinality is bounded.  A non-zero rate per
   name doubles as a migration tracker for RFC-0066 Phase 4: when
   counter for a given name stays at zero across deploys, the name
   can be safely removed from
   [deprecated_logical_profile_names]. *)
let metric_deprecated_profile_name_filter =
  "masc_cascade_deprecated_profile_name_filter_total"

let on_deprecated_profile_name_filter ~name =
  Prometheus.inc_counter metric_deprecated_profile_name_filter
    ~labels:[ ("name", name) ]
    ()

(* [Cascade_config_loader.detect_capability_mismatches] is the twin
   of [detect_fallback_cycles]: both walk the catalog's
   [fallback_cascade] graph looking for RFC-0055/0058 violations.
   The cycle detector already emits
   [metric_cascade_fallback_cycle_detected_total] (pre-iter-32);
   the capability-mismatch detector emitted only a string in the
   load_catalog Error, with no Prometheus surface.

   Iter 5's [serving_last_known_good{reason="validation_failed"}]
   does fire when load_catalog Errors, but it conflates capability
   mismatches with every other validation fault — operators
   couldn't distinguish "a fallback edge violates the capability
   subset invariant" (RFC-0055 actionable) from "cascade.toml is
   syntactically malformed" (RFC-0058 §9 actionable).

   Bumped by the number of mismatches in a single load_catalog
   invocation rather than +1 per call, so a single deploy that
   introduces N broken edges spikes proportionally (same shape as
   iter 7 leak / iter 9 route_config_error / iter 15
   auto_expansion_fanout).

   Cardinality: 1 series. *)
let metric_capability_mismatch = "masc_cascade_capability_mismatch_total"

let on_capability_mismatch ~count =
  if count > 0 then
    Prometheus.inc_counter metric_capability_mismatch
      ~delta:(float_of_int count)
      ()

(* [Cascade_routes.route_bindings_from_json] silently drops two
   classes of malformed [routes] entry that escaped iter 9's
   schema-error counters (which cover missing-target-profile and
   unknown-route-key, NOT value-shape faults):

     invalid_value         — [target_of_route_value] returned None.
                              Either the value isn't a string (legacy
                              encoding) and isn't an [Assoc] with a
                              [target] field (declarative encoding),
                              or the [Assoc] exists but has no
                              [target] subfield.  Typical: operator
                              typoed the [target] subfield key.
     empty_key_or_target   — both encodings produced a value but the
                              route key or target name is the empty
                              string after trimming.

   The silent drop means the [routes] table looks valid from a
   parser perspective (no Error raised) but a route the operator
   declared just doesn't make it into the catalog.  Downstream
   route resolution then falls back to iter-30
   [route_resolve_fallback] — but the iter-30 counter can't
   distinguish "declared but malformed" from "never declared".

   Cardinality: 2 reasons = 2 series. *)
let metric_route_binding_dropped = "masc_cascade_route_binding_dropped_total"

let on_route_binding_dropped ~reason =
  Prometheus.inc_counter metric_route_binding_dropped
    ~labels:[ ("reason", reason) ]
    ()

(* [Cascade_config_loader.parse_weighted_item] silently drops two
   classes of malformed entry in the legacy [<name>_models]
   JSON-shape list:

     missing_or_empty_model — value is an [Assoc] but the [model]
                               subfield is missing, not a string,
                               or trims to empty.
     invalid_value_type     — value is neither a string (legacy
                               compact encoding) nor an [Assoc]
                               (declarative encoding).

   The drops happen via [List.filter_map] in [load_profile_weighted],
   producing a smaller-than-declared candidate list with no signal.
   Counter complement to iter 33 [route_binding_dropped] — same
   value-shape-fault class, different containing table.

   Most cascade.toml deploys land on the 5-layer declarative schema
   (which never hits this code path), so a non-zero rate flags
   legacy [<name>_models] fixtures still in use — doubles as an
   RFC-0066 Phase 4 migration tracker for fixture leftover.

   Cardinality: 2 reasons = 2 series. *)
let metric_weighted_item_dropped =
  "masc_cascade_weighted_item_dropped_total"

let on_weighted_item_dropped ~reason =
  Prometheus.inc_counter metric_weighted_item_dropped
    ~labels:[ ("reason", reason) ]
    ()
