(** Keeper Guard — Pure guard evaluation (RFC-0002).

    Evaluates a [measurement_snapshot] against frozen thresholds
    and returns typed events. This is the bridge between the NonDet
    boundary (measurement capture) and the Det core (state machine).

    INVARIANT: [evaluate] is a pure function.
    Given the same [measurement_snapshot], it MUST return the same events.
    No I/O, no mutable state reads, no clock queries. *)

(** Evaluate all guard conditions against a frozen measurement snapshot.
    Returns all events that fire, ordered by priority (highest first).
    The caller decides whether to act on the first or process all. *)
val evaluate :
  Keeper_measurement.measurement_snapshot ->
  Keeper_state_machine.event list

(** Derive the surviving context-capacity actions from one frozen snapshot. *)
val context_actions :
  Keeper_measurement.measurement_snapshot ->
  Keeper_state_machine.context_actions

(** Select the highest-priority event from the guard output.
    Priority: Crash > Compact > Handoff > No_transition.
    Returns [Heartbeat_ok] if the list is empty (no transitions needed). *)
val prioritized_event :
  Keeper_state_machine.event list ->
  Keeper_state_machine.event
