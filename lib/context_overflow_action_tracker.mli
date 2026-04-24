(** Context overflow imminent → action detector (#9935).

    OAS emits three related events per keeper:
    - [ContextOverflowImminent] when context ≥ threshold (e.g. 95%)
    - [ContextCompactStarted] when compaction begins
    - [ContextCompacted] when compaction completes

    Issue #9935 evidence: 45 imminent events per day fleet-wide
    with no observability on whether any reduction action followed.
    The scheduler can continue firing turns on an overflowed
    keeper, which then burns out on the oas_timeout_budget
    (#9933). This module closes the loop by tracking per-keeper
    state and emitting metrics when an imminent event goes
    unanswered within a grace window.

    Design: pure in-memory per-keeper state, single-domain
    Stdlib.Mutex (no Eio dependency — matches
    Cascade_health_tracker after #9873). Called from the
    oas_sse_bridge event translation path, which is serialized
    per-agent.

    Observability contract:
    - [masc_context_overflow_imminent_total{keeper=X}] counter
    - [masc_context_overflow_action_taken_total{keeper=X}] —
      increments when an action (compact_started or compacted)
      is observed within [grace_window_seconds ()] of imminent.
    - [masc_context_overflow_no_action_total{keeper=X}] —
      increments once when a new imminent arrives with a
      previous pending imminent still unanswered past the
      grace window. Latched per episode: re-arms when an
      action event clears the pending.
    - A [Log.Server.warn] tagged [#9935] fires on first
      unanswered episode only. *)

val grace_window_seconds : unit -> float
(** Time window after [ContextOverflowImminent] during which a
    compaction/reduction action must land to count as "action
    taken". Read from [MASC_CONTEXT_OVERFLOW_GRACE_SEC] (default
    60.0). Re-read on each call; safe for test-time [putenv]. *)

val record_imminent : keeper_name:string -> ts:float -> unit
(** Call on [ContextOverflowImminent]. Increments the imminent
    counter and starts the grace timer. If a prior imminent was
    still pending past the grace window at [ts], fires the
    no-action counter + warn log (latched so repeated imminent
    spam does not flood alerts). *)

val record_action : keeper_name:string -> unit
(** Call on [ContextCompactStarted] or [ContextCompacted]. Clears
    the pending imminent and increments the action-taken
    counter. Calls with no pending imminent are silent. *)

val current_pending_since : keeper_name:string -> float option
(** [Some ts] if there is an unanswered imminent for this keeper;
    [None] otherwise. Used by tests. *)

val reset_all_for_test : unit -> unit
