(** Pure lifecycle admission for keeper execution boundaries.

    The persisted [paused] bit remains the pause authority.  A typed
    [Dead_tombstone] latch refines that state into a terminal lifecycle state,
    even if a racing/stale writer cleared [paused].  Missing or malformed latch
    detail while [paused = true] is fail-closed as an unclassified pause. *)

type paused_latch = private
  | Classified of Keeper_latched_reason.t
  | Unclassified

type state = private
  | Active
  | Paused of paused_latch
  | Dead_tombstone

val state :
  paused:bool ->
  latched_reason:Keeper_latched_reason.t option ->
  state

type manual_one_shot_admission =
  | Manual_admitted_active
  | Manual_admitted_paused_recovery of paused_latch
  | Manual_denied_dead_tombstone

val admit_manual_one_shot : state -> manual_one_shot_admission

type autonomous_denial =
  | Autonomous_paused of paused_latch
  | Autonomous_dead_tombstone

type autonomous_admission =
  | Autonomous_admitted
  | Autonomous_denied of autonomous_denial

val admit_autonomous : state -> autonomous_admission

(** Stable boundary projections.  Execution decisions must pattern-match on
    the typed values above rather than compare these strings. *)
val paused_latch_to_wire : paused_latch -> string
val state_to_wire : state -> string
val autonomous_denial_to_wire : autonomous_denial -> string
