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
