(** Env_config_oas_bridge — per-caller OAS bridge timeout SSOT (#10094).

    Replaces seven hardcoded [Masc_oas_bridge.run_safe ~timeout_s:N.N]
    literals scattered across the lib tree. Each caller is named so
    its hardcoded default is preserved (compute-heavy budgets at
    120/180s) or raised (fantasy 60s budgets at 300s), while the
    operator can tune any single caller via env without touching the
    others.

    Lookup order in {!timeout_sec} (top wins):
    1. Per-caller env [MASC_OAS_BRIDGE_TIMEOUT_<CALLER>_SEC].
    2. Legacy per-caller env (#9629 migration window).
    3. Per-caller checked-in default.
    4. Global env [MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC] — only for
       unknown callers; not an override.
    5. [300.0] hardcoded fallback.

    The default-resolution table, env-var name builders, and
    legacy-alias map are intentionally hidden — callers interact
    through [timeout_sec ~caller ()] only. *)

(** Named caller identity. [Unknown of <key>] handles a future caller
    without a typed default; resolution falls through to the global
    env / hardcoded fallback rather than failing closed. *)
type caller =
  | Auto_responder
  | Dashboard_provider_runs
  | Autoresearch_codegen
  | Keeper_persona_authoring
  | Server_openai_compat
  | Tool_deep_review
  | Anti_rationalization
  | Governance_judge
  | Operator_judge
  | Unknown of string

val caller_key : caller -> string
(** Stable lowercase string identifier for [caller], used by
    Prometheus labels and env-var name construction. *)

val timeout_sec : caller:caller -> unit -> float
(** Resolve the OAS bridge timeout (seconds) for [caller] using the
    five-step lookup order documented above. *)

val global_env_var : string
(** [MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC] — env var consulted in
    step 4 of {!timeout_sec}'s lookup order. Exposed for tests
    (#9629 / #10094) that need to twiddle it via [Unix.putenv]. *)

val per_caller_env_var : caller:caller -> string
(** [MASC_OAS_BRIDGE_TIMEOUT_<CALLER>_SEC] — env var consulted in
    step 1 of {!timeout_sec}'s lookup order. Exposed for tests. *)

val known_callers : unit -> caller list
(** The typed-default caller table exposed for tests that want to
    walk every caller (e.g. assert that the legacy alias map covers
    them all). *)

val global_default_sec : float
(** Hardcoded final fallback (seconds) — also reused as the typed
    default for compute-heavy callers ({!Auto_responder} /
    {!Dashboard_provider_runs} / {!Governance_judge} /
    {!Operator_judge}). Exposed so tests can pin the per-caller
    table without hardcoding the literal. *)
