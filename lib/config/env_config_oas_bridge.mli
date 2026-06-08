(** Env_config_oas_bridge — per-caller OAS bridge timeout SSOT (#10094).

    Each remaining caller is named so its hardcoded default is preserved
    or bounded for advisory dashboard judges, while the operator can tune
    any single caller via env without touching the others.

    Lookup order in {!timeout_sec} (top wins):
    1. Per-caller env [MASC_OAS_BRIDGE_TIMEOUT_<CALLER>_SEC].
    2. Per-caller checked-in default.
    3. Global env [MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC] — only for
       unknown callers; not an override.
    4. [300.0] hardcoded fallback.

    The default-resolution table, env-var name builders, and
    timeout parser are intentionally hidden — callers interact through
    [timeout_sec ~caller ()] only. *)

(** Named caller identity. [Unknown of <key>] handles a future caller
    without a typed default; resolution falls through to the global
    env / hardcoded fallback rather than failing closed. *)
type caller =
  | Anti_rationalization
  | Governance_judge
  | Operator_judge
  | Unknown of string

(** Stable lowercase string identifier for [caller], used by
    Otel_metric_store labels and env-var name construction. *)
val caller_key : caller -> string

(** Resolve the OAS bridge timeout (seconds) for [caller] using the
    four-step lookup order documented above. Invalid env values, including
    non-positive and non-finite floats, fall back to [global_default_sec]. *)
val timeout_sec : caller:caller -> unit -> float

(** [MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC] — env var consulted in
    step 4 of {!timeout_sec}'s lookup order. Exposed for tests
    (#9629 / #10094) that need to twiddle it via [Unix.putenv]. *)
val global_env_var : string

(** [MASC_OAS_BRIDGE_TIMEOUT_<CALLER>_SEC] — env var consulted in
    step 1 of {!timeout_sec}'s lookup order. Exposed for tests. *)
val per_caller_env_var : caller:caller -> string

(** The typed-default caller table exposed for tests. *)
val known_callers : unit -> caller list

(** Hardcoded final fallback (seconds). Exposed so tests can pin the
    fallback without hardcoding the literal. *)
val global_default_sec : float

(** Legacy default for advisory dashboard judge callers
    ({!Governance_judge} / {!Operator_judge}). Retained as a
    named pin so test fixtures that previously asserted on
    [45.0] keep a stable reference, but no longer the active
    default — the {b governance_judge_no_timeout} value below
    replaces the [Governance_judge | Operator_judge] arms in
    the per-caller default table. *)
val dashboard_judge_default_sec : float

(** Active default for [{!Governance_judge}] and [{!Operator_judge}]:
    [Float.infinity], meaning the bridge applies no wrapper timeout
    to those callers.  See the [known_default_sec] comment in
    [.ml] for the 2026-06-08 root cause (45s wrapper firing before
    the OAS provider's first response and propagating fleet-wide
    idle).  Per-caller env overrides
    [MASC_OAS_BRIDGE_TIMEOUT_GOVERNANCE_JUDGE_SEC] /
    [MASC_OAS_BRIDGE_TIMEOUT_OPERATOR_JUDGE_SEC] still win for
    operators who want a finite budget. *)
val governance_judge_no_timeout : float
