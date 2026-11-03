(** Extract task lifecycle transition executor
    
    This module was extracted from [Workspace_task] as part of #16078.
    It owns the pure backlog-shape construction for task lifecycle
    transitions: counting releases and building the persisted backlog
    update. *)

open Masc_domain

type transition_backlog_update =
  { backlog : Masc_domain.backlog
  ; transitioned_task : Masc_domain.task
  ; persisted_handoff_context : Masc_domain.task_handoff_context option
  }

(* RFC-0365. A handoff note is authored on the way out and read on the way in,
   so the two classes of transition must treat the field differently.

   Exit-class takes the argument: the closing owner is stating what it leaves
   behind, and an absent argument there is a deliberate "nothing to say".

   Entry-class keeps what is already stored. The incoming owner does not author
   a handoff — [Tool_task_args.parse] returns [Ok None] for an absent field and
   its comment calls that "the expected shape for entry-class actions" — so
   taking the argument here overwrites the previous owner's note with [None].
   That erased it at exactly the boundary it exists to cross: verified on the
   live fleet 2026-08-06 by release(handoff) then claim by a second agent,
   after which backlog.json held null and the second agent's world state
   rendered no "Prior handoff" line.

   Staleness does not need erasure to be expressible: [updated_by] and
   [updated_at] are populated on every record, and the renderer already labels
   the line "Prior handoff". *)
let handoff_context_after ~action ~previous ~argument =
  match action with
  | Masc_domain.Release
  | Masc_domain.Done_action
  | Masc_domain.Submit_for_verification
  | Masc_domain.Cancel -> argument
  | Masc_domain.Claim | Masc_domain.Start -> previous
;;

(* What *this* transition put on the record, which is a different question from
   what the task now holds: the caller broadcasts this, and a claim that
   inherited the previous owner's note did not author it. Entry-class is [None]
   here even when the task keeps a note. *)
let handoff_context_authored_by ~action ~argument =
  match action with
  | Masc_domain.Release
  | Masc_domain.Done_action
  | Masc_domain.Submit_for_verification
  | Masc_domain.Cancel -> argument
  | Masc_domain.Claim | Masc_domain.Start -> None
;;

let release_cycle_count ~action task =
  match action with
  | Masc_domain.Release -> task.cycle_count + 1
  | Masc_domain.Cancel
  | Masc_domain.Claim
  | Masc_domain.Start
  | Masc_domain.Done_action
  | Masc_domain.Submit_for_verification ->
    task.cycle_count
;;

let update_task_for_transition ~action ~new_status ~handoff_context task =
  { task with
    task_status = new_status
  ; handoff_context =
      handoff_context_after
        ~action
        ~previous:task.handoff_context
        ~argument:handoff_context
  ; cycle_count = release_cycle_count ~action task
  }
;;

let build_backlog_update ~backlog ~task ~action ~new_status ~handoff_context =
  let transitioned_task =
    update_task_for_transition ~action ~new_status ~handoff_context task
  in
  let tasks =
    List.map
      (fun (candidate : task) ->
         if String.equal candidate.id task.id then transitioned_task else candidate)
      backlog.tasks
  in
  let persisted_handoff_context =
    handoff_context_authored_by ~action ~argument:handoff_context
  in
  (* [write_backlog] stamps version/last_updated at the commit point. *)
  { backlog = { backlog with tasks }
  ; transitioned_task
  ; persisted_handoff_context
  }
;;
