(** Keeper_goal_assignment_wake — RFC-0315 P3 W0 producer.

    Enqueues a [Keeper_event_queue.Goal_assigned] stimulus for each goal that
    newly entered a keeper's [active_goal_ids], and wakes the keeper fiber
    when it is running. Mirrors
    [Workspace_goals.enqueue_goal_verification_failed_wake].

    Edge semantics: callers pass the pre-change and post-change id lists;
    only ids present in [new_ids] and absent from [old_ids] enqueue.
    Re-applying an unchanged configuration (boot-time TOML reconcile)
    therefore produces no wake, and removals never wake. *)

val added_goal_ids : old_ids:string list -> new_ids:string list -> string list
(** Ids in [new_ids] that are not in [old_ids], in [new_ids] order. *)

val enqueue_goal_assigned_wakes :
  config:Workspace.config ->
  keeper_name:string ->
  assigned_by:string ->
  old_ids:string list ->
  new_ids:string list ->
  unit ->
  string list
(** Enqueue one [Goal_assigned] stimulus per added goal (title resolved from
    Goal_store at enqueue time; a goal deleted between validation and
    enqueue falls back to its id as the label). Wakes the keeper fiber only
    when its registry phase is [Running]; otherwise the durable queue entry
    delivers on the next cycle. Returns the added goal ids. *)
