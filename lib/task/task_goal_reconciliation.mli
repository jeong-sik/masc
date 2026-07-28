type ready = {
  goal_id : string;
  triggering_task_id : string;
}

val ready_after_terminal_task :
  config:Workspace_core.config -> task_id:string -> ready option
(** Re-read the canonical Task, Goal link, and Goal stores after a terminal
    Task commit. Returns a reconciliation cue only when the triggering Task is
    terminal, belongs to exactly one executing Goal, and every linked Task is
    terminal. This is evidence that Goal-level synthesis is ready, not authority
    to complete the Goal. *)
