(** Typed projection of actionable world-observation signals. *)

type actionable_signal =
  | Has_unclaimed_tasks
  | Has_board_activity
  | No_actionable_signal
      (** Caller observed neither tasks nor board activity in the structured
          world snapshot. *)

val actionable_signal_label : actionable_signal -> string

(** Structured per-turn world snapshot consumed by
    [classify_actionable_signal]. This is intentionally smaller than
    {!Keeper_world_observation.world_observation}: it carries only the
    advisory labels needed for keeper prompt/metric context. *)
type world_observation = {
  unclaimed_task_count : int;
      (** Number of unclaimed tasks in the keeper's queue.
          Mirrors the integer rendered into the
          ["**Unclaimed tasks (N total ...) ..."] section. *)
  board_activity_count : int;
      (** Count of fresh board entries the keeper has not yet
          processed. Mirrors the count rendered after
          ["### Board Activity"]. *)
}

(** Project the full keeper heartbeat observation into the compact advisory
    snapshot. The task count uses [claimable_task_count], not global backlog
    size. *)
val of_keeper_world_observation :
  Keeper_world_observation.world_observation -> world_observation

(** [classify_actionable_signal o] returns the most-specific
    actionable signal observed in [o], following the precedence
    [unclaimed_tasks > board_activity].

    The precedence reflects the action ladder a keeper should
    descend: a claimable task is the highest-leverage move; engaging
    with board activity is next.

    Boolean-compatible:
    [classify_actionable_signal o <> No_actionable_signal]
    is the structured equivalent of an observed actionable context. *)
val classify_actionable_signal : world_observation -> actionable_signal

(** [is_actionable s] is [false] iff [s = No_actionable_signal].
    Provided so callers comparing the structured signal against the
    legacy boolean can do so without a manual pattern match. *)
val is_actionable : actionable_signal -> bool
