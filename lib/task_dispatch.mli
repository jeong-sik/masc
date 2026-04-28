(** Task_dispatch — runtime backend selection for MASC tasks.

    Currently routes everything to the JSONL backend (Coord.* file
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

(** {1 Backend variant} *)

type task_backend =
  | Jsonl  (** JSONL backend (Coord.* file operations) *)

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

    Each delegates to the {!Coord} JSONL backend.  All take a
    {!Coord.config} as the first positional argument.  Errors are
    returned as {!Masc_error.t} variants — the wording
    inside [TaskInvalidState] / [TaskNotFound] is operator-visible
    through the JSON-RPC error envelope, so callers must not
    reformat it. *)

val add_task :
  Coord.config ->
  title:string ->
  priority:int ->
  description:string ->
  (string, Masc_error.t) result
(** [add_task config ~title ~priority ~description] persists a new
    task via {!Coord.add_task} and returns the freshly assigned
    task id.  Always [Ok _] on the JSONL backend (the variant
    return type leaves room for backends that can fail at insert
    time). *)

val get_task :
  Coord.config ->
  task_id:string ->
  (Types.task option, Masc_error.t) result
(** [get_task config ~task_id] reads the JSONL backlog and returns
    [Ok (Some task)] when a task with the given id exists,
    [Ok None] otherwise.  Linear scan over the backlog —
    callers running this in tight loops should batch through
    {!list_tasks} instead. *)

val list_tasks :
  Coord.config ->
  ?include_done:bool ->
  ?include_cancelled:bool ->
  unit ->
  (Types.task list, Masc_error.t) result
(** [list_tasks config ?include_done ?include_cancelled ()] returns
    every task in the backlog, filtering out terminal states by
    default.  Both flags default to [false] so the dashboard sees
    only the active queue.

    Active states ([Todo] / [Claimed] / [InProgress] /
    [AwaitingVerification]) always pass through. *)

val validate_transition :
  current:Types.task_status ->
  next:Types.task_status ->
  task_id:string ->
  (unit, Masc_error.t) result
(** [validate_transition ~current ~next ~task_id] enforces the
    terminal-state rule: neither [Done _] nor [Cancelled _] may
    transition to either terminal state.  The error message
    embeds [task_id] + the rendered current/next status so
    operator logs surface the full context.  Pure — no side
    effects, suitable for use in client-side preflight checks. *)

val update_status :
  Coord.config ->
  task_id:string ->
  status:Types.task_status ->
  (unit, Masc_error.t) result
(** [update_status config ~task_id ~status] reads the backlog,
    runs {!validate_transition}, and on success rewrites the task
    list with the new status, bumping [version] and refreshing
    [last_updated] (ISO 8601 of the current monotonic time).
    Errors:
    - [TaskNotFound task_id] when the task is absent.
    - [TaskInvalidState <message>] from {!validate_transition}. *)

val delete_task :
  Coord.config ->
  task_id:string ->
  (unit, Masc_error.t) result
(** [delete_task config ~task_id] filters the task out of the
    backlog and writes it back with [version] bumped.  Idempotent
    — deleting a non-existent task is silently a no-op (always
    returns [Ok ()]).  Always [Ok _] on the JSONL backend. *)
