type enqueue_outcome =
  | Not_ready
  | Backlog_read_failed of { detail : string }
  | No_keeper_target of { goal_id : string }
  | Keeper_target_lookup_failed of { goal_id : string; detail : string }
  | Enqueued of { goal_id : string; keeper_name : string }
  | Already_present of { goal_id : string; keeper_name : string }
  | Enqueue_failed of { goal_id : string; keeper_name : string; detail : string }

type reconciliation_summary = {
  ready_count : int;
  enqueued_count : int;
  already_present_count : int;
  unresolved_count : int;
  failed_count : int;
}

val enqueue_if_ready :
  config:Workspace.config ->
  completing_agent_name:string ->
  task_id:string ->
  enqueue_outcome
(** Re-read canonical Goal/Task state after a terminal Task commit, durably
    enqueue one typed reconciliation stimulus, then wake its Keeper. The
    registered or persisted Keeper assignment that covers
    the Goal is authoritative. When no unambiguous assignment exists, an
    exact live or persisted [agent_name] binding may identify the producer;
    identity strings are never parsed to invent a Keeper name. The function
    never mutates Goal phase, and reports a non-authoritative recovery snapshot
    as [Backlog_read_failed]. *)

val reconcile_startup :
  config:Workspace.config -> reconciliation_summary
(** Re-scan canonical Goal, Task, and link state and atomically restore missing
    reconciliation stimuli. Safe to call on every existing supervisor
    reconciliation pass: accounted stimuli are reported as already present,
    storage failures remain visible and retryable, and no Goal state changes. *)
