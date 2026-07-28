type enqueue_outcome =
  | Not_ready
  | No_keeper_target of { goal_id : string }
  | Enqueued of { goal_id : string; keeper_name : string }
  | Already_present of { goal_id : string; keeper_name : string }
  | Enqueue_failed of { goal_id : string; keeper_name : string; detail : string }

val enqueue_if_ready :
  config:Workspace.config ->
  completing_agent_name:string ->
  task_id:string ->
  enqueue_outcome
(** Re-read canonical Goal/Task state after a terminal Task commit, durably
    enqueue one typed reconciliation stimulus, then wake its Keeper. The
    completing Keeper is preferred; an external completion may target the sole
    registered Keeper whose [active_goal_ids] contains the Goal. The function
    never mutates Goal phase. *)
