(** Extract task lifecycle transition executor
    
    This module was extracted from [Coord_task] as part of #16078.
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
  | Masc_domain.Submit_for_verification
  | Masc_domain.Submit_pr_evidence ->
    true
  | Masc_domain.Claim
  | Masc_domain.Start
  | Masc_domain.Cancel
  | Masc_domain.Approve_verification
  | Masc_domain.Reject_verification ->
    false
;;

let normalize_task_before_status ~action task =
  match action with
  | Masc_domain.Claim ->
    task
    |> Coord_task_claim.clear_soft_do_not_reclaim_reason
    |> Coord_task_claim.clear_stale_worktree_binding
  | Masc_domain.Release -> Coord_task_claim.clear_stale_worktree_binding task
  | Masc_domain.Start
  | Masc_domain.Done_action
  | Masc_domain.Cancel
  | Masc_domain.Submit_for_verification
  | Masc_domain.Submit_pr_evidence
  | Masc_domain.Approve_verification
  | Masc_domain.Reject_verification ->
    task
;;

let release_counters ~action task handoff_context =
  match action with
  | Masc_domain.Release ->
    ( task.cycle_count + 1
    , Coord_task_claim.derive_release_do_not_reclaim_reason task handoff_context )
  | Masc_domain.Claim
  | Masc_domain.Start
  | Masc_domain.Done_action
  | Masc_domain.Cancel
  | Masc_domain.Submit_for_verification
  | Masc_domain.Submit_pr_evidence
  | Masc_domain.Approve_verification
  | Masc_domain.Reject_verification ->
    task.cycle_count, task.do_not_reclaim_reason
;;

let update_task_for_transition ~action ~new_status ~handoff_context task =
  let task = normalize_task_before_status ~action task in
  let cycle_count, do_not_reclaim_reason =
    release_counters ~action task handoff_context
  in
  { task with
    task_status = new_status
  ; handoff_context =
      (if action_persists_handoff_context action then handoff_context else None)
  ; cycle_count
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
