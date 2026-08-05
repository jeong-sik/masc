(** Extract task lifecycle transition executor

    This module was extracted from [Workspace_task] as part of #16078.
    It owns the pure backlog-shape construction for task lifecycle
    transitions: normalizing tasks before status changes, computing
    release counters, and building the persisted backlog update.

    It sits between {!Workspace_task_lifecycle.decide} and the
    storage/event side effects in {!Workspace_task.transition_task_r}. *)

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
(** [handoff_context] is authored by an exit-class action only
    ([Release | Done_action | Submit_for_verification | Cancel]); for those it
    replaces whatever the task held, and passing [None] there means the closing
    owner had nothing to state.

    Entry-class actions ([Claim | Start]) neither read nor write it: their
    caller never supplies one — {!Tool_task_args} returns [None] for an absent
    field and calls that the expected shape — so applying the argument would
    erase the previous owner's note at the one boundary it exists to cross
    (RFC-0365). The stored note carries [updated_by] and [updated_at], so a note
    from an earlier owner stays attributable rather than being deleted for
    being stale. *)
