(** Bounded ring buffer of Cascade {b strategy decisions}, one per cycle.

    {!Cascade_strategy.order_candidates} currently logs cycle-level
    filtering through {!Log.Misc.info}.  That is useful for tail -f
    but invisible to the dashboard; operators cannot answer
    "how often did Phase B Sticky reuse the same provider?" or
    "how long were Circuit_breaker_cycling retries in the last hour?".

    This module captures the decision outcome of every cycle iteration
    of {!Oas_worker_named.try_cascade} as a ring event, so the dashboard
    can surface recent runtime behaviour alongside the TLA+-verified
    strategy kind.

    Contracts:
    - Size is fixed at init, read from [MASC_STRATEGY_TRACE_SIZE]
      (default 1024, clamped to [[16, 65536]]).  Changing the env after
      first use has no effect; the ring is lazily initialised once.
    - Drop-oldest on overflow: recording into a full ring overwrites
      the oldest slot in place, no allocation on steady state.
    - [record] and [snapshot] are thread-safe via a plain stdlib
      [Mutex] (same pattern as {!Cascade_client_capacity_history}).
    - [snapshot] returns events newest-first so the dashboard can
      render without a reverse pass.

    @since 0.9.10 *)

(** Decision outcome for a single cycle iteration.

    - [Ordered]: strategy returned a non-empty candidate list; the caller
      proceeded with the FSM.
    - [Filtered_empty]: strategy filtered every candidate (e.g. every
      provider in cooldown or slot-full); caller will backoff + retry.
    - [Exhausted]: [Filtered_empty] on the last cycle, so the cascade
      gave up and returned the exhaustion error. *)
type event_kind = Ordered | Filtered_empty | Exhausted

(** One decision event.

    [ts] is a Unix timestamp (seconds).
    [cascade_name] is the cascade.json profile name carried as a typed
    runtime cascade identifier.
    [strategy] is {!Cascade_strategy.kind_to_string} of the active kind.
    [cycle] is 0-based, matching the [n] in [oas_worker_named.cycle_loop].
    [candidates_in] is the input list size (post-[resolve_strategy]).
    [candidates_out] is the list size returned by [order_candidates]
    for this cycle (same as [candidates_in] for pure [Failover]).
    [backoff_ms] is the backoff about to be applied for [Filtered_empty];
    [0] for [Ordered] and [Exhausted]. *)
type event = {
  ts : float;
  cascade_name : Keeper_cascade_profile.runtime_name;
  strategy : string;
  cycle : int;
  candidates_in : int;
  candidates_out : int;
  backoff_ms : int;
  kind : event_kind;
  trace_id : string option;
      (** Optional outer trace identifier for cross-system correlation.

          Step 0a (PR #11154) added [keeper_turn_id] propagation through
          [log.ml] and [keeper_tool_call_log.ml]; this field carries the
          same identifier into the cascade strategy ring so the dashboard
          and [bin/masc_trace] can join cascade decisions to the originating
          turn timeline.

          Producers that do not yet thread the identifier should pass
          [None]; downstream consumers must treat [None] as "unknown",
          not as failure. *)
  confidence_score : float option;
      (** Average log probability per token from the LLM response, if
          available.  Populated from {!Cascade_health_tracker} on
          [Ordered] outcomes; [None] for [Filtered_empty] and
          [Exhausted]. *)
}

val record : event -> unit
(** Append [event] to the ring.  Drops the oldest entry if the ring
    is full.  Safe to call from multiple fibers/domains; serialised
    via a stdlib [Mutex]. *)

val snapshot : ?limit:int -> ?cascade:string -> unit -> event list
(** Newest-first snapshot of recorded events.

    @param limit  maximum number of events returned (default 100,
           clamped to the ring's current count).
    @param cascade  filter by [cascade_name].  Omitting returns
           events for every cascade.

    Filters compose: both [limit] and [cascade] apply together, with
    [limit] applied after filtering. *)

val clear : unit -> unit
(** Test helper: drop every recorded event and reset the write head. *)

val size : unit -> int
(** Test helper: current number of recorded events (≤ ring capacity). *)

val capacity : unit -> int
(** Test helper: the ring's fixed capacity as resolved from
    [MASC_STRATEGY_TRACE_SIZE]. *)

val kind_to_string : event_kind -> string
(** Serialise [event_kind] as the dashboard-facing label: ["ordered"],
    ["filtered_empty"], ["exhausted"]. *)
