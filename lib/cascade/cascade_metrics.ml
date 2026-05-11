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
   a real recovery from steady-state validated calls. *)
let metric_lkg_recovery = "masc_cascade_lkg_recovery_total"

let on_lkg_recovery () =
  Prometheus.inc_counter metric_lkg_recovery ()

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
