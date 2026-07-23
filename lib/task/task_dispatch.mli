(** Task_dispatch — runtime backend selection for MASC tasks.

    Currently routes everything to the JSONL backend (Workspace.* file
    operations).  The variant is pinned at one constructor to keep
    the compile-time pivot point explicit: a future second backend
    (Postgres, etc.) extends {!task_backend} and forces every
    [match] site to be revisited.

    Backend state is initialised lazily — {!backend} auto-promotes
    {!Uninitialized} to {!Active} {!Jsonl} on first call so callers
    do not need an explicit init unless they want the side-effect
    log.  The internal mutable state is hidden; callers reach it
    through {!is_initialized} / {!init_jsonl} / {!reset_for_test} /
    {!backend}.

    @since 0.7.0 *)

module Workspace = Workspace_core

(** {1 Backend variant} *)

type task_backend =
  | Jsonl  (** JSONL backend (Workspace.* file operations) *)

val is_initialized : unit -> bool
(** [is_initialized ()] reports whether {!init_jsonl} or {!backend}
    has run.  Useful for tests that need to assert the boot
    sequence. *)

val init_jsonl : unit -> unit
(** [init_jsonl ()] explicitly activates the JSONL backend and logs
    at [Log.Task.info].  Idempotent — calling twice logs a
    [Log.Task.warn] but does not crash.  Most callers can omit this
    and rely on {!backend}'s lazy promotion. *)

val reset_for_test : unit -> unit
(** [reset_for_test ()] returns the backend state to
    {!Uninitialized} for fresh test setup.  Test-only; production
    code must not call this. *)

val backend : unit -> task_backend
(** [backend ()] returns the active backend, auto-initialising
    JSONL if {!Uninitialized}.  The auto-init logs at
    [Log.Task.info] — the same line {!init_jsonl} would emit, so
    repeated [backend] calls do not produce duplicate boot
    messages. *)

(** {1 Dispatch functions}

    Each delegates to the {!Workspace} JSONL backend.  All take a
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
(** [add_task config ~title ~priority ~description] persists a new
    task via {!Workspace.add_task} and returns the freshly assigned
    task id.  Always [Ok _] on the JSONL backend (the variant
    return type leaves workspace for backends that can fail at insert
    time). *)

val get_task :
  Workspace.config ->
  task_id:string ->
  (Masc_domain.task option, Masc_error.t) result
(** [get_task config ~task_id] reads the JSONL backlog and returns
    [Ok (Some task)] when a task with the given id exists,
    [Ok None] otherwise.  Linear scan over the backlog —
    callers running this in tight loops should batch through
    {!list_tasks} instead. *)

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
    [AwaitingVerification]) always pass through. *)

(* [validate_transition] / [update_status] were retired by RFC-0323 G-7:
   a direct status writer with its own 2-state terminal check bypassed the
   workspace FSM ([Workspace.transition_task_r]) — including the RFC-0308
   done lifecycle guard — and had zero production
   callers. Status changes go through the FSM; there is no side door. *)

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
