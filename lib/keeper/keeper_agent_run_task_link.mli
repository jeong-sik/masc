(** RFC-0145 PR-9: extract Phase 5 task-link wire from
    [keeper_agent_run.run_turn] Step 8 body (L2010-L2060).

    Links execution artifacts to the current task if one exists,
    skipping when the (keeper, task, trace_id) tuple has already
    been recorded.  Reads/writes via
    [Coord.link_task_execution_artifacts_r], with
    [task_link_already_recorded] / [mark_task_link] sibling
    helpers (re-exported from [Turn_helpers]).

    Lock contention or transient I/O on [link_task_execution_artifacts_r]
    raises an exception; this wrapper catches non-[Cancelled] exceptions
    and converts them into [Masc_domain.System (IoError ...)] so the
    warn path logs the failure instead of unwinding the whole keeper
    turn.

    Side effects only.  [Eio.Cancel.Cancelled] re-raised.
    No-op when [task_id = None]. *)
val link_if_needed
  :  config:Coord.config
  -> keeper_name:string
  -> task_id:Keeper_id.Task_id.t option
  -> trace_id:Keeper_id.Trace_id.t
  -> unit
