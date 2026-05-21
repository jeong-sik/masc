(** Coord task release variants extracted from coord_task.ml.

    Provides {release,force_release,force_done,force_cancel}_task_r —
    small helpers that delegate to [transition_task_r] with terminal
    transitions. *)

open Masc_domain

let release_task_r config ~agent_name ~task_id ?expected_version ?handoff_context ()
  : string Masc_domain.masc_result
  =
  transition_task_r
    config
    ~agent_name
    ~task_id
    ~action:Masc_domain.Release
    ?expected_version
    ?handoff_context
    ()
;;

(** Force-release a task regardless of assignee. Keeper privilege. *)
let force_release_task_r config ~agent_name ~task_id ?handoff_context ()
  : string Masc_domain.masc_result
  =
  transition_task_r
    config
    ~agent_name
    ~task_id
    ~action:Masc_domain.Release
    ?handoff_context
    ~force:true
    ()
;;

(** Force-done a task regardless of assignee. Keeper privilege. *)
let force_done_task_r config ~agent_name ~task_id ~notes ()
  : string Masc_domain.masc_result
  =
  transition_task_r
    config
    ~agent_name
    ~task_id
    ~action:Masc_domain.Done_action
    ~notes
    ~force:true
    ()
;;

(** Force-cancel a task regardless of assignee. System privilege.
    Used by [Verification_protocol.check_timeouts] to expire
    [AwaitingVerification] tasks whose verifier deadline has passed,
    so the FSM does not stall and re-emit Timeout posts forever. *)
let force_cancel_task_r config ~agent_name ~task_id ~reason ()
  : string Masc_domain.masc_result
  =
  transition_task_r
    config
    ~agent_name
    ~task_id
    ~action:Masc_domain.Cancel
    ~reason
    ~force:true
    ()
;;

(** Cancel a task - A2A compatible *)
