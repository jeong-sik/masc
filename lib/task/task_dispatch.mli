(** Task_dispatch — task operations over the bound Workspace store.

    Task persistence is the filesystem state owned by the supplied
    {!Workspace.config}.

    @since 0.7.0 *)

module Workspace = Workspace_core

(** {1 Dispatch functions}

    Each delegates to the bound {!Workspace} store. All take a
    {!Workspace.config} as the first positional argument.  Errors are
    returned as {!Masc_error.t} variants — the wording
    inside [TaskInvalidState] / [TaskNotFound] is operator-visible
    through the JSON-RPC error envelope, so callers must not
    reformat it. *)

val add_task :
  Workspace.config ->
  title:string ->
  priority:int ->
  description:string ->
  (string, Masc_error.t) result
(** [add_task config ~title ~priority ~description] persists a new task via
    {!Workspace.add_task} and returns the freshly assigned task id. *)

val get_task :
  Workspace.config ->
  task_id:string ->
  (Masc_domain.task option, Masc_error.t) result
(** [get_task config ~task_id] reads the task backlog and returns
    [Ok (Some task)] when a task with the given id exists,
    [Ok None] otherwise. A primary/recovery read failure is returned as a
    structured [System_error.IoError], never raised through this result API.
    Linear scan over the backlog — callers running this in tight loops should
    batch through {!list_tasks} instead. *)

val list_tasks :
  Workspace.config ->
  ?include_done:bool ->
  ?include_cancelled:bool ->
  unit ->
  (Masc_domain.task list, Masc_error.t) result
(** [list_tasks config ?include_done ?include_cancelled ()] returns
    every task in the backlog, filtering out terminal states by
    default.  Both flags default to [false] so the dashboard sees
    only the active queue.

    Active states ([Todo] / [Claimed] / [InProgress] /
    [AwaitingVerification]) always pass through. A primary/recovery read
    failure is returned as a structured [System_error.IoError], never raised
    through this result API. *)

val delete_task :
  Workspace.config ->
  task_id:string ->
  (unit, Masc_error.t) result
(** [delete_task config ~task_id] takes the Workspace [.backlog] file lock,
    filters the task out of the
    backlog and writes it back with [version] bumped, then clears any
    agent [current_task] cache still pointing to [task_id].  Idempotent
    — deleting a non-existent task is silently a no-op (always
    returns [Ok ()] when the backlog is readable). *)
