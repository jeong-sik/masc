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
