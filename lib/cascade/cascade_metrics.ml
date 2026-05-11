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
