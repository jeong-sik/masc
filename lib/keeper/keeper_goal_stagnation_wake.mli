(** Keeper_goal_stagnation_wake — RFC-0310 §3.3 producer.

    Enqueues a [Keeper_event_queue.Goal_stagnation] stimulus for each of a
    keeper's active goals that is live ([Goal_phase.Executing]) and has not
    been touched for at least the stagnation threshold, then wakes the keeper
    fiber when it is running. Mirrors [Keeper_goal_assignment_wake].

    Edge semantics (why this is not a blind clock):
    - The episode key is (goal_id, goal.updated_at). A goal that is advanced
      bumps [updated_at] and so opens a fresh episode; a goal that stays stale
      keeps the same key.
    - Within one episode the wake fires once: the live-queue identity dedup
      covers the pre-consume window, and the reaction ledger's
      [turn_started_seen] gate covers re-scans after the keeper has already
      taken a turn on the episode. [arrived_at] is pinned to the episode
      timestamp so the ledger stimulus id is stable across scans.
    - Only [Executing] goals qualify ([Goal_phase.admits_self_directed_progress]);
      terminal, paused, blocked, and awaiting-verdict goals never wake. *)

val stagnation_of_goal :
  now:float ->
  threshold_sec:float ->
  Goal_store.goal ->
  Keeper_event_queue.goal_stagnation option
(** The pure detection core, exposed for unit tests. Returns [Some] only when
    the goal is live ([Goal_phase.Executing]), its [updated_at] parses, and it
    has been untouched for at least [threshold_sec]. [None] for any
    non-executing phase, a fresh goal, or an unparseable timestamp (fail
    closed — an undecidable timestamp does not wake). *)

val enqueue_goal_stagnation_wakes :
  config:Workspace.config ->
  keeper_name:string ->
  active_goal_ids:string list ->
  now:float ->
  threshold_sec:float ->
  unit ->
  string list
(** Enqueue one [Goal_stagnation] stimulus per stale live goal the keeper has
    not yet attended this episode. Wakes the keeper fiber only when its
    registry phase is [Running]; otherwise the durable queue entry delivers on
    the next cycle. Returns the goal ids freshly enqueued by this scan (empty
    when nothing is newly stale or all stale episodes were already delivered). *)
