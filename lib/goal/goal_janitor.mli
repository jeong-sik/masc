(** Goal_janitor — Periodic cleanup of stale and dropped goals.

    Four sweep rules:
    1. Purge: delete [Dropped] goals older than
       [dropped_ttl_days] (default 7).
    2. Stagnate: mark [Active] goals with no update after
       [stagnant_days] (default 30) as [Dropped].
    3. Orphan: remove [active_goal_ids] entries from each
       [keeper_meta] that reference non-existent goals in the Goal
       Store.
    4. Escalate: report stale unclaimed tasks without goal linkage.

    @since 2.236.0 *)

(** {1 Configuration} *)

type sweep_config = {
  dropped_ttl_days : int;  (** Delete Dropped goals after this many days. *)
  stagnant_days : int;     (** Drop Active goals with no update after this many days. *)
  orphan_task_escalation_age_seconds : int;
      (** Report unclaimed tasks without goal linkage after this age. *)
}

val default_config : sweep_config

(** {1 Result} *)

type sweep_result = {
  purged : int;     (** Dropped goals deleted. *)
  stagnated : int;  (** Active goals marked Dropped. *)
  orphans : int;    (** Orphaned [active_goal_ids] cleaned. *)
  orphan_tasks : int;  (** Stale unclaimed tasks missing goal linkage. *)
}

val sweep_result_to_yojson : sweep_result -> Yojson.Safe.t

(** {1 Helpers} *)

(** [prune_active_goal_ids ~valid_goal_ids active_ids] keeps only
    ids in [valid_goal_ids]. Returns the pruned list and the number
    of removed ids. *)
val prune_active_goal_ids :
  valid_goal_ids:string list ->
  string list ->
  string list * int

(** [audit_unclaimed_goal_orphan_tasks ~valid_goal_ids
    ~min_age_seconds tasks] returns stale [Todo] tasks with no structured
    [goal_id] and no current legacy title-tag linkage. *)
val audit_unclaimed_goal_orphan_tasks :
  ?now:float ->
  valid_goal_ids:string list ->
  min_age_seconds:int ->
  Masc_domain.task list ->
  (Masc_domain.task * int) list

(** {1 Entry point} *)

(** Run a full sweep: goal purge / stagnate, then keeper
    [active_goal_ids] prune. Writes updated state to disk. *)
val run : ?config:sweep_config -> Coord.config -> sweep_result
