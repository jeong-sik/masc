(** Extract task lifecycle transition executor
    
    This module was extracted from [Workspace_task] as part of #16078.
    It owns the pure backlog-shape construction for task lifecycle
    transitions: normalizing tasks before status changes, computing
    release counters, and building the persisted backlog update. *)

open Masc_domain

type transition_backlog_update =
  { backlog : Masc_domain.backlog
  ; persisted_handoff_context : Masc_domain.task_handoff_context option
  }

let action_persists_handoff_context = function
  | Masc_domain.Release
  | Masc_domain.Done_action
  | Masc_domain.Submit_for_verification ->
    true
  | Masc_domain.Claim
  | Masc_domain.Start
  | Masc_domain.Cancel
  | Masc_domain.Approve_verification
  | Masc_domain.Reject_verification ->
    true
;;

let normalize_task_before_status ~action task =
  match action with
  | Masc_domain.Claim ->
    Workspace_task_claim.clear_reclaim_decision task
  | Masc_domain.Release -> task
  | Masc_domain.Start
  | Masc_domain.Done_action
  | Masc_domain.Cancel
  | Masc_domain.Submit_for_verification
  | Masc_domain.Approve_verification
  | Masc_domain.Reject_verification ->
    task
;;

(** Upper bound for [cycle_count] to prevent unbounded growth from
    claim->release hot-potato patterns (issue #18853).  100 allows
    5x headroom above the [severe] escalation threshold (20) while
    capping the context bloat measured at 1000+ cycles. *)
let max_cycle_count = 100

let release_counters ~action task handoff_context =
  match action with
  | Masc_domain.Release ->
    ( min (task.cycle_count + 1) max_cycle_count
    , Workspace_task_claim.derive_release_reclaim_policy task handoff_context
    , Workspace_task_claim.derive_release_do_not_reclaim_reason task handoff_context )
  | Masc_domain.Claim
  | Masc_domain.Start
  | Masc_domain.Done_action
  | Masc_domain.Cancel
  | Masc_domain.Submit_for_verification
  | Masc_domain.Approve_verification
  | Masc_domain.Reject_verification ->
    task.cycle_count, task.reclaim_policy, task.do_not_reclaim_reason
;;

let update_task_for_transition ~action ~new_status ~handoff_context task =
  let task = normalize_task_before_status ~action task in
  let cycle_count, reclaim_policy, do_not_reclaim_reason =
    release_counters ~action task handoff_context
  in
  { task with
    task_status = new_status
  ; handoff_context =
      (if action_persists_handoff_context action then handoff_context else None)
  ; cycle_count
  ; reclaim_policy
  ; do_not_reclaim_reason
  }
;;

let build_backlog_update ~backlog ~task_id ~action ~new_status ~handoff_context =
  let tasks =
    List.map
      (fun (task : task) ->
         if String.equal task.id task_id
         then update_task_for_transition ~action ~new_status ~handoff_context task
         else task)
      backlog.tasks
  in
  let persisted_handoff_context =
    if action_persists_handoff_context action then handoff_context else None
  in
  { backlog =
      { tasks
      ; last_updated = now_iso ()
      ; version = backlog.version + 1
      }
  ; persisted_handoff_context
  }
;;
