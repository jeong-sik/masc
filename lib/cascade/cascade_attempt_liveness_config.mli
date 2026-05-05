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

val budget_for_label : string -> Cascade_attempt_liveness.budget
(** Map a cascade provider label (e.g. [codex_cli], [claude_code],
    [gemini_cli], [glm-coding], [ollama_only], [llama-server]) to a
    per-profile budget.

    Unknown labels fall back to {!Cascade_attempt_liveness.cloud_fast}
    which is the conservative cloud-streaming default. *)

val reset_cache_for_test : unit -> unit
(** Test-only: reset the cached flag read so a new value of
    [MASC_CASCADE_ATTEMPT_LIVENESS] takes effect. Production callers
    must not invoke this. *)
