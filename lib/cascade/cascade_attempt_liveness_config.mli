(** Tri-state env flag + per-label budget lookup for the cascade
    attempt-liveness gate (RFC-0022 PR-2/4 §2).

    The flag [MASC_CASCADE_ATTEMPT_LIVENESS] selects one of three modes:

    - [off]      — wrapper bypassed entirely, baseline behaviour.
    - [observe]  — observer constructed; counters emit; never raises.
    - [enforce]  — observer raises [Liveness_kill] via [Eio.Switch.fail]
                   on the first {!Cascade_attempt_liveness.Outcome}.

    Default is [observe] (RFC-0022 §9 Phase A).

    The mode is read once and cached on first call (mirrors
    [Keeper_admission_glue.use_new_admission]) so that mid-attempt env
    edits do not split-brain the observer.

    @stability Evolving
    @since 0.190.0 *)

type mode =
  | Off
  | Observe
  | Enforce

val current_mode : unit -> mode
(** Cached env-flag read. First call reads
    [MASC_CASCADE_ATTEMPT_LIVENESS] and caches the result. Subsequent
    calls return the cached value. Default when unset / unparseable is
    {!Observe}. *)

val mode_label : mode -> string
(** Stable label for telemetry / Prometheus counter values. One of
    [off | observe | enforce]. *)

val budget_for_provider_id :
  provider_id:string -> Cascade_attempt_liveness.budget
(** Map a cascade [provider_id] (e.g. [codex_cli], [claude_code],
    [gemini_cli], [glm-coding], [ollama_only], [llama-server]) to a
    per-profile budget.

    The argument is the {b provider} dispatch key — not a model id.
    Callers should pass the value from
    [Provider_adapter.provider_label_of_config provider_cfg] or an
    equivalent provider-level identifier.

    Unknown provider ids fall back to
    {!Cascade_attempt_liveness.cloud_fast} which is the conservative
    cloud-streaming default. *)

val reset_cache_for_test : unit -> unit
(** Test-only: reset the cached flag read so a new value of
    [MASC_CASCADE_ATTEMPT_LIVENESS] takes effect. Production callers
    must not invoke this. *)

val outer_wall_for_attempt
  :  mode:mode
  -> observer_attached:bool
  -> per_provider_timeout_s:float option
  -> provider_id:string
  -> float option
(** RFC-0022 §1 — backstop wall for the legacy [per_provider_timeout_s]
    knob.

    Decides what (if anything) {!Eio.Time.with_timeout_exn} should
    enforce around an attempt, given the active liveness mode and
    whether an observer is attached.

    - [Enforce] + observer attached: returns [None]. The observer is
      the authority and drives [Switch.fail] on TTFT, inter-chunk, or
      attempt wall budget breach. The legacy outer wall must not
      pre-empt it.
    - [Off] / [Observe], or no observer: returns
      [Some (max t (budget_for_provider_id ~provider_id).attempt_wall_max)]
      when [per_provider_timeout_s = Some t]. Slow-but-legitimate
      streams (local Ollama 27B / 70B+) get the profile's attempt wall
      so the legacy 120s knob cannot prematurely fall back the cascade.
    - No legacy timeout configured ([per_provider_timeout_s = None]):
      returns [None] (no outer wall).

    @since 0.20.0 *)
