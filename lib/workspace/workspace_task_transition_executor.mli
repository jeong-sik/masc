(** Extract task lifecycle transition executor

    This module was extracted from [Workspace_task] as part of #16078.
    It owns the pure backlog-shape construction for task lifecycle
    transitions: counting releases and building the persisted backlog
    update.

    It sits between {!Workspace_task_lifecycle.decide} and the
    storage/event side effects in {!Workspace_task.transition_task_r}. *)

type transition_backlog_update =
  { backlog : Masc_domain.backlog
  ; transitioned_task : Masc_domain.task
  ; persisted_handoff_context : Masc_domain.task_handoff_context option
  ; replaced_unreadable_handoff : Masc_domain.replaced_unreadable_handoff option
      (** The stored [Handoff_unreadable] this exit-class transition replaced,
          or [None] when it replaced a readable note, nothing, or (entry-class)
          kept the stored value. The caller writes it on the transition log
          row so the replaced value is recorded (#38219). *)
  }

val unreadable_handoff_replaced
  :  Masc_domain.stored_handoff_context option
  -> Masc_domain.replaced_unreadable_handoff option
(** What overwriting a stored handoff with a new value removes, when the stored
    value is [Handoff_unreadable]; [None] for a readable or absent note. Every
    path that overwrites the field records this on its transition row, so an
    unreadable note is recorded when it is replaced (#38219). *)

val build_backlog_update
  :  backlog:Masc_domain.backlog
  -> task:Masc_domain.task
  -> action:Masc_domain.task_action
  -> new_status:Masc_domain.task_status
  -> handoff_context:Masc_domain.task_handoff_context option
  -> transition_backlog_update
(** [task] is the authoritative member selected from [backlog]. The returned
    [transitioned_task] is the same immutable value installed in [backlog]:
    submission capture and post-commit notification use that value, including
    the current handoff, rather than reconstructing a status-only Task.

    [handoff_context] is authored by an exit-class action only
    ([Release | Done_action | Submit_for_verification | Cancel]); for those it
    replaces whatever the task held, and passing [None] there means the closing
    owner had nothing to state.

    Entry-class actions ([Claim | Start]) neither read nor write it: their
    caller never supplies one — {!Tool_task_args} returns [None] for an absent
    field and calls that the expected shape — so applying the argument would
    erase the previous owner's note at the one boundary it exists to cross.
    The stored note carries [updated_by] and [updated_at], so a note
    from an earlier owner stays attributable rather than being deleted for
    being stale. *)
