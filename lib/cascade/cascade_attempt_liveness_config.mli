(** Tri-state env flag + per-provider budget lookup for the cascade
    attempt-liveness gate (RFC-0022 PR-2/4 §2 + RFC-0058 Phase 5.2b).

    The flag [MASC_CASCADE_ATTEMPT_LIVENESS] selects one of three modes:

    - [off]      — wrapper bypassed entirely, baseline behaviour.
    - [observe]  — observer constructed; counters emit; never raises.
    - [enforce]  — observer raises [Liveness_kill] via [Eio.Switch.fail]
                   on the first {!Cascade_attempt_liveness.Outcome}.

    Default is [observe] (RFC-0022 §9 Phase A).

    The mode is read once and cached on first call (mirrors
    [Keeper_admission_glue.use_new_admission]) so that mid-attempt env
    edits do not split-brain the observer.

    {2 RFC-0058 Phase 5.2b}

    [budget_for_provider_id] resolves the per-provider liveness budget
    by reading [\[providers.<id>.liveness\] class] from
    [config/cascade.toml]. A *successful* parse is cached; a *failed*
    parse is not cached and is re-attempted on the next call, so a
    config that becomes available (or is repaired) after boot takes
    effect without a restart. Until a parse succeeds the fallback is
    [cloud_fast].

    Phase 5.2b deleted the hardcoded
    [match provider_id with "codex_cli" | "claude_code" | …] block that
    previously routed cascade prefixes to liveness classes. The
    cascade-config SSOT (RFC-0058 §2.4) is now the only source for the
    provider → class mapping.

    @stability Evolving
    @since 0.190.0 *)

type mode =
  | Off
  | Observe
  | Enforce

(** Cached env-flag read. First call reads
    [MASC_CASCADE_ATTEMPT_LIVENESS] and caches the result. Subsequent
    calls return the cached value. Default when unset / unparseable is
    {!Observe}. *)
val current_mode : unit -> mode

(** Stable label for telemetry / Prometheus counter values. One of
    [off | observe | enforce]. *)
val mode_label : mode -> string

(** Map a cascade [provider_id] (e.g. [codex_cli], [claude_code],
    [gemini_cli], [glm-coding], [ollama]) to a per-class budget.

    The argument is the {b provider} dispatch key — not a model id.
    Callers should pass the value from
    [Provider_adapter.provider_label_of_config provider_cfg] or an
    equivalent provider-level identifier.

    [?cfg] override (test-only): bypass the cached active cascade
    config and resolve against an explicit one. Production callers
    omit [?cfg] and rely on the cached load from
    [Config_dir_resolver.cascade_path_candidate]. The trailing [()]
    is required so OCaml can erase the optional argument
    (warning 16 — see RFC-0058 Phase 5.2b).

    Unknown provider ids — id not declared in cascade.toml, or
    cascade.toml failed to parse — fall back to
    {!Cascade_attempt_liveness.cloud_fast}, matching the conservative
    default the deleted hardcoded match used. The validator R-rule for
    [liveness.class] (Phase 5.2b) ensures every shipped provider
    declares its class, so this fallback only fires for ad-hoc / custom
    integrations. *)
val budget_for_provider_id
  :  ?cfg:Cascade_declarative_types.cascade_config
  -> provider_id:string
  -> unit
  -> Cascade_attempt_liveness.budget

(** Test-only: reset the cached env-flag and declarative-config caches
    so the next call re-reads [MASC_CASCADE_ATTEMPT_LIVENESS] and
    re-parses [config/cascade.toml]. Production callers must not
    invoke this. *)
val reset_cache_for_test : unit -> unit

(** RFC-0022 §1 — backstop wall for the legacy [per_provider_timeout_s]
    knob.

    Decides what (if anything) {!Eio.Time.with_timeout_exn} should
    enforce around an attempt, given the active liveness mode and
    whether an observer is attached.

    - [Enforce] + observer attached: returns [None]. The observer is
      the authority and drives [Switch.fail] on TTFT, inter-chunk, or
      attempt wall budget breach. The legacy outer wall must not
      pre-empt it.
    - [Off] / [Observe] + observer attached: returns
      [Some (max t (budget_for_provider_id ~provider_id ()).attempt_wall_max)]
      when [per_provider_timeout_s = Some t]. Slow-but-legitimate
      streams (local Ollama 27B / 70B+) get the profile's attempt wall
      so the legacy 120s knob cannot prematurely fall back the cascade.
    - No observer attached (any mode): returns [per_provider_timeout_s]
      unchanged. Without an observer there is no per-provider budget
      to clamp against, so the caller's legacy knob is honored as-is.
    - No legacy timeout configured ([per_provider_timeout_s = None]):
      returns [None] (no outer wall).

    @since 0.20.0 *)
val outer_wall_for_attempt
  :  mode:mode
  -> observer_attached:bool
  -> per_provider_timeout_s:float option
  -> provider_id:string
  -> float option
