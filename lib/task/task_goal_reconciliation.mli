type ready = {
  goal_id : string;
  triggering_task_id : string;
}

type startup_ready = {
  ready : ready;
  completing_agent_name : string;
}

val ready_after_terminal_task :
  config:Workspace_core.config -> task_id:string -> ready option
(** Re-read the canonical Task, Goal link, and Goal stores after a terminal
    Task commit. Returns a reconciliation cue only when the triggering Task is
    terminal, belongs to exactly one executing Goal, and every linked Task is
    terminal. This is evidence that Goal-level synthesis is ready, not authority
    to complete the Goal. *)

val ready_executing_goals :
  config:Workspace_core.config -> startup_ready list
(** Deterministically scans canonical Goal, Task, and link state for executing
    Goals whose linked Tasks are all terminal. The latest terminal Task
    supplies the stable stimulus id and delivery actor. This is restart
    reconciliation only; it never mutates Goal or Task state. *)
