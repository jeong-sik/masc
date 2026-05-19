(** Typed escalation state for the [Keeper_turn_livelock] dispatch guard
    log noise.

    Background
    ──────────
    [Keeper_turn_livelock.guard_and_record_turn_start] gates dispatch
    once a turn exhausts its retry budget ([Attempts_exhausted]) or
    stays stuck too long ([Stuck_age_exceeded]). The block itself is
    correct — the underlying turn cannot make progress and dispatch
    must not fire — but the call site at
    [Keeper.Unified_turn] (the supervisor loop) re-invokes the same
    [(keeper, turn_id)] roughly every 30 seconds, and the guard
    returns [Blocked] each time. The result is a tight ERROR-level
    log loop visible in production system_log:

    - 2026-05-19 00:00–00:10 slice: 107 [keeper turn livelock guard
      blocked dispatch] ERROR lines from 4 keepers
      (sangsu turn=651 ×28, nick0cave turn=766 ×29, echo turn=61 ×25,
       analyst turn=445 ×25).
    - Steady-state projection: ~15K events/day, fully attributable to
      the same 4 [(keeper, turn_id)] tuples re-blocking.

    The block itself is *not* the bug — the bug is that the operator
    sees the same fact restated 30× per turn. This module records
    each block and classifies the result so the caller can emit one
    durable [Threshold_park] ERROR plus a Prometheus counter, and
    demote the noisy intermediate emissions to DEBUG.

    Closed sum type, no catch-all. The [gate_kind] mirrors
    [Keeper_turn_livelock.gate_reason] so the classifier and the
    metric label remain in lock-step with the upstream guard.

    Workaround posture
    ──────────────────
    This is a *symptom suppression* layer for the log surface. The
    root fix lives one level up in [Keeper.Unified_turn] / the
    supervisor — a [Blocked] dispatch should either finalise the
    turn (drop the keeper into [Disp_pause_human]) or back off the
    next supervisor sweep so the same turn_id is not retried every
    30 s. That change touches the supervisor lifecycle and is
    deferred to its own RFC.

    For now, the [Threshold_park] outcome gives the operator a
    one-line ERROR after [default_park_threshold] identical blocks
    and a Prometheus counter for dashboarding; subsequent blocks
    return [`Repeated] and the caller is expected to DEBUG-log
    instead of ERROR-log.

    [WORKAROUND-CARRYOVER]: this module is a noise-dedupe layer, not
    a structural fix for the underlying livelock retry pattern.
    Track the supervisor-side root fix on a follow-up issue.

    Threading
    ─────────
    Backed by an in-memory [Hashtbl.t] under a [Mutex]. Process
    lifetime; not persisted. A server restart sees the first
    occurrence emit at ERROR again, which is the desired behaviour
    (operator-visible "this is still happening after restart"). *)

(** Closed-enum mirror of [Keeper_turn_livelock.gate_reason]
    constructors. The kind is used both as the dedupe fingerprint
    component and as a stable Prometheus label.

    The string form round-trips with [gate_kind_of_string] and is
    aligned with [Keeper_turn_livelock.gate_reason_kind] so the two
    surfaces never diverge silently. *)
type gate_kind =
  | Attempts_exhausted
      (** Per-turn retry budget exhausted; dispatch blocked. *)
  | Stuck_age_exceeded
      (** Turn has been re-attempted past the stuck-age threshold. *)

(** Stable label for log/metric dimensions. Round-trips with
    [gate_kind_of_string]. *)
val gate_kind_to_string : gate_kind -> string

(** Inverse of [gate_kind_to_string]. Returns [None] for unrecognised
    labels rather than collapsing to a default, so callers can detect
    contract drift between this module and
    [Keeper_turn_livelock.gate_reason_kind]. *)
val gate_kind_of_string : string -> gate_kind option

(** All [gate_kind] inhabitants in declaration order. Used by
    exhaustiveness tests. *)
val all_gate_kinds : gate_kind list

(** Outcome of a [record_block] call. The caller is the
    [Keeper.Unified_turn] livelock branch; the outcome dictates how
    that branch logs the block:

    - [`First] — first time this [(keeper, gate_kind)] pair has
      been blocked in this process lifetime. Emit ERROR (preserve
      existing operator-visible signal).

    - [`Repeated count] — the same pair has been blocked before;
      [count] is the total block count including this call (>=2)
      and is strictly less than [park_threshold]. Demote the log
      line to DEBUG and bump the [livelock_blocks_repeated_total]
      counter. The block still happens — only the log surface
      changes.

    - [`Threshold_park payload] — the [park_threshold] consecutive
      identical blocks have now been seen for this
      [(keeper, gate_kind)]; [payload.count] is the running block
      count and [payload.park_threshold] echoes the configured
      threshold. The caller should emit a single durable ERROR
      ("threshold reached, parking log surface") and bump the
      [livelock_blocks_threshold_park_total] counter. Subsequent
      blocks for the same pair return [`Repeated] until
      [reset_for_keeper] is called (typically by the supervisor
      cleanup branch that already resets [Keeper_turn_livelock]
      state on keeper death). *)
(** Carrier for the [`Threshold_park] outcome below. Bundled as a
    nominal record because polymorphic variants do not accept
    inline-record payloads. [count] is the running block count at
    the moment the threshold tripped (>= [park_threshold]) and
    [park_threshold] echoes the threshold the caller observed. *)
type threshold_park_payload =
  { count : int
  ; park_threshold : int
  }

type record_outcome =
  [ `First
  | `Repeated of int
  | `Threshold_park of threshold_park_payload
  ]

(** [default_park_threshold] is the number of identical
    [(keeper, gate_kind)] blocks tolerated at ERROR / DEBUG before
    a [`Threshold_park] outcome fires. Tuned against the production
    sample (107 blocks/10 min, 4 keepers, ~30 s dispatch cadence):
    threshold 5 means the operator sees one ERROR line plus five
    DEBUG-demoted intermediates before the [Threshold_park] ERROR,
    and any further blocks for the same pair are [`Repeated] +
    DEBUG only. *)
val default_park_threshold : int

(** [record_block ~keeper ~gate_kind] registers a livelock dispatch
    block for [keeper] with kind [gate_kind] and returns the
    classification. The fingerprint is [(keeper, gate_kind)] — two
    different turn_ids for the same keeper with the same gate_kind
    collapse into the same bucket on purpose: the operator-visible
    pattern is "this keeper is stuck", not "this specific turn_id is
    stuck again".

    The default park threshold is [default_park_threshold]; callers
    that need a different threshold (e.g. tests) can override via
    [?park_threshold]. *)
val record_block
  :  ?park_threshold:int
  -> keeper:string
  -> gate_kind:gate_kind
  -> unit
  -> record_outcome

(** [reset_for_keeper ~keeper] removes all per-keeper state. Called
    by the [Keeper_supervisor] cleanup branch that already resets
    [Keeper_turn_livelock] bookkeeping on keeper death, so a restarted
    keeper starts with a fresh classifier. *)
val reset_for_keeper : keeper:string -> unit

(** Reset all internal state. Test-only entry point — do not call
    from production code. Exposed so unit tests can enforce
    isolation between cases. *)
val reset_for_test : unit -> unit

(** Current number of distinct [(keeper, gate_kind)] entries.
    Diagnostic only; never used for control flow. *)
val cardinality : unit -> int

(** [block_count ~keeper ~gate_kind] returns the current block count
    for the given pair, or [0] when no state exists. Diagnostic /
    introspection only; never used for control flow inside the
    module. *)
val block_count : keeper:string -> gate_kind:gate_kind -> int
