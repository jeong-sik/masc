(** Build the persisted task/backlog shape for task lifecycle transitions.

    This module owns the mutation plan that sits between
    {!Coord_task_lifecycle.decide} and the storage/event side effects in
    {!Coord_task.transition_task_r}. *)

type transition_backlog_update =
  { backlog : Masc_domain.backlog
  ; persisted_handoff_context : Masc_domain.task_handoff_context option
  }

val build_backlog_update
  :  backlog:Masc_domain.backlog
  -> task_id:string
  -> action:Masc_domain.task_action
  -> new_status:Masc_domain.task_status
  -> handoff_context:Masc_domain.task_handoff_context option
  -> transition_backlog_update
