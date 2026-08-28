(** Planning_eio — the session current-task pointer.

    Historically this module also owned a per-task plan document store
    (task_plan / notes / errors / deliverable as Markdown under
    [planning/<task_id>/]); the five tools that wrote it
    (masc_plan_init/update/get, masc_note_add, masc_deliver) were retired
    together with that store, and only the current-task pointer the task
    claim chain maintains remains. Pure synchronous module — no Eio
    scheduling primitives despite the [_eio] suffix. *)

val get_current_task : Workspace_core.config -> string option
(** [get_current_task config] returns the persisted current task
    id, or [None] when no current task is set. *)

val set_current_task : Workspace_core.config -> task_id:string -> (unit, string) result
(** [set_current_task config ~task_id] persists the current task
    id, returning [Error _] when an existing directory cannot be
    quarantined before the file write. *)

val clear_current_task : Workspace_core.config -> unit
(** [clear_current_task config] removes the persisted current task
    file. *)
