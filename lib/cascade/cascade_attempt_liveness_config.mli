(** Tri-state env flag + living budget selection for the cascade
    attempt-liveness gate (RFC-0022 PR-2/4 §2).

    The flag [MASC_CASCADE_ATTEMPT_LIVENESS] selects one of three modes:

    - [off]      — wrapper bypassed entirely, baseline behaviour.
    - [observe]  — observer constructed; counters emit; never raises.
    - [enforce]  — observer raises [Liveness_kill] via [Eio.Switch.fail]
                   on the first {!Cascade_attempt_liveness.Outcome}.

    When the env var is absent, current production default is [enforce].
    Empty or unparseable values resolve to [observe].

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
    calls return the cached value. *)

val mode_label : mode -> string
(** Stable label for telemetry / Prometheus counter values. One of
    [off | observe | enforce]. *)

type success_sample =
  { ttft_ms : float
  ; max_inter_chunk_ms : float
  ; wall_ms : float
  }
(** Successful attempt timing sample for one concrete provider/model
    candidate. Values are milliseconds and are recorded only after the
    liveness FSM reaches [Success]. Failed, killed, or rejected attempts do not
    train future budgets. *)

type budget_source =
  | Bootstrap
  | Observed_success of { samples : int }

type resolved_budget =
  { budget : Cascade_attempt_liveness.budget
  ; source : budget_source
  }

val budget_source_label : budget_source -> string
(** Stable debug/receipt label: [bootstrap] or [observed_success]. *)

val budget_for_candidate : candidate_key:string -> resolved_budget
(** Resolve the budget for a concrete provider/model candidate. The key should
    be derived from [Provider_adapter.provider_model_health_key_of_config] or
    an equivalent model-scoped runtime key. When no successful samples exist,
    returns {!Cascade_attempt_liveness.bootstrap} with [source = Bootstrap]. *)

val record_success_sample :
  candidate_key:string -> success_sample -> unit
(** Append a successful attempt timing sample for [candidate_key]. Invalid
    negative/non-finite values are ignored. *)

val reset_cache_for_test : unit -> unit
(** Test-only: reset the cached flag read so a new value of
    [MASC_CASCADE_ATTEMPT_LIVENESS] takes effect. Production callers
    must not invoke this. *)

val reset_success_history_for_test : unit -> unit
(** Test-only: clear the in-process success-history budget store. *)

val success_sample_count_for_test : candidate_key:string -> int
(** Test-only: number of retained samples for [candidate_key]. *)

val outer_wall_for_attempt
  :  mode:mode
  -> observer_attached:bool
  -> per_provider_timeout_s:float option
  -> candidate_key:string
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
    - [Off] / [Observe] + observer attached: returns
      [Some (max t (budget_for_candidate ~candidate_key).budget.attempt_wall_max)]
      when [per_provider_timeout_s = Some t]. Successful prior attempts for
      the same candidate can raise the legacy wall so a slow-but-honest stream
      is not killed before the liveness observer's own deadline.
    - No observer attached (any mode): returns [per_provider_timeout_s]
      unchanged. Without an observer there is no per-provider budget
      to clamp against, so the caller's legacy knob is honored as-is.
    - No legacy timeout configured ([per_provider_timeout_s = None]):
      returns [None] (no outer wall).

    @since 0.20.0 *)
