(** Background shell task lifecycle for the Execute process surface.

    Maps claude-code's [backgroundTaskId] / [BashOutput] / [KillShell]
    triad onto OCaml Unix primitives.

    Tick 6a (current): pull-based.  [read] drains whatever is pending
    on the child's pipes without blocking.  No long-lived fiber, no
    Eio switch — the MCP polling loop IS the drain cadence.  Child
    runs in its own session via {!Process_eio.spawn_detached};
    tree-kill via [Unix.kill (-pgid)] reaches descendants.

    Tick 7 (current partial): stdout/stderr are retained in a bounded
    in-memory line ring (default 5000 lines, override with
    [MASC_KEEPER_SHELL_RING_LINES]).  Slow readers get the retained
    suffix plus [bytes_dropped_*] evidence instead of unbounded heap
    growth.

    Tick 7 follow-up: introduce a daemon switch and push-based
    drainers so slow readers can't stall producers, plus
    append-only backing files under
    \`.masc/keeper/<name>/bg/<id>.{out,err}\` for persistence across
    reader restarts.  That tick will reintroduce a [val init :
    sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> unit] hook
    separately from [spawn] so this signature stays stable. *)

type task_id = private string
(** Opaque UUID-like handle. Constructible only via [spawn]. *)

val task_id_to_string : task_id -> string

val task_id_of_string : string -> (task_id, string) result
(** Rehydrate a task_id from JSON at the MCP boundary without raising. *)

val task_id_of_string_exn : string -> task_id
(** Rehydrate a task_id from JSON at the MCP boundary. Raises
    [Invalid_argument] on a syntactically invalid handle — callers must
    be the MCP layer that accepted the string as a tool argument. *)

type snapshot = {
  stdout_since : string;
      (** Bytes emitted on stdout since [since]. *)
  stderr_since : string;
      (** Bytes emitted on stderr since [since]. *)
  closed : bool;
      (** True once the process has exited. No further bytes will
          arrive after a [closed = true] snapshot. *)
  status : Unix.process_status option;
      (** Raw process status. Use
          {!Exec_semantic.interpret} in [masc_exec] to turn this into
          a typed classification; bg_task itself stays
          semantics-agnostic to avoid a circular sub-library
          dependency. *)
  bytes_dropped_stdout : int;
  bytes_dropped_stderr : int;
      (** Head-drop counters for the ring buffers; non-zero means the
          caller read too late to see every byte. *)
}

type spawn_error =
  | Spawn_failed of string
  | Too_many_tasks of { keeper : string; limit : int }
  | Invalid_cwd of string

val spawn :
  ?base_path:string ->
  keeper:string ->
  argv:string list ->
  cwd:string ->
  envp:string array ->
  timeout_sec:float ->
  unit ->
  (task_id, spawn_error) result
(** Fork a long-lived shell task.  Runs until it exits, until
    [timeout_sec] elapses (SIGTERM -> grace -> SIGKILL), or until
    {!kill} is invoked.  The child starts in its own session; tree-kill
    addresses [-pgid].

    [timeout_sec = 0.0] disables the timeout — typical for keeper
    polling loops that expect to {!kill} explicitly.

    [base_path] when supplied enables PID-file persistence at
    \`<base_path>/.masc/keeper/<keeper>/bg/<task_id>.pid\`.  The file
    records \`pid\\npgid\\nstarted_at\\n\` so {!reap_orphans} can recover
    stranded process groups across keeper restarts.  When omitted,
    no filesystem state is written. *)

type read_error =
  | Unknown_task of task_id
  | Read_failed of string

val read :
  task_id ->
  since_stdout:int ->
  since_stderr:int ->
  (snapshot, read_error) result
(** Non-blocking snapshot of the task's output. [since_*] are byte
    offsets into the cumulative stream; the returned [stdout_since]
    contains bytes at offsets [>= since_stdout]. *)

type kill_error =
  | Unknown_task_kill of task_id
  | Kill_failed of string

val kill :
  task_id ->
  signal:int ->
  grace_sec:float ->
  (unit, kill_error) result
(** Send [signal] to the pgroup; if the process is still alive after
    [grace_sec], escalate to [SIGKILL]. Idempotent on
    already-dead tasks. *)

val list : keeper:string -> task_id list
(** All currently-tracked tasks owned by [keeper]. *)

val list_with_started_at : keeper:string -> (task_id * float) list
(** Same roster as {!list}, paired with the unix-timestamp at which
    each task was spawned.  The timestamp is captured by
    {!Process_eio.spawn_detached} before the child enters its session
    and is immutable for the task's lifetime, so observers can compute
    wall-clock elapsed time without consulting the child process or
    reading the PID file. *)

type lifetime_guard = { acquire : unit -> (unit -> unit) }
(** Process-wide guard for long-lived background task resources.
    [acquire ()] runs before {!Process_eio.spawn_detached}; the returned
    release callback is held until the task process exits or is reaped.
    stdout/stderr read FDs may remain open until the next {!read} drains
    and closes the final snapshot. *)

type completion = {
  base_path : string option;
  keeper : string;
  task_id : task_id;
  status : Unix.process_status;
  finished_at : float;
}
(** Process completion event emitted exactly once per tracked task. The process
    layer remains semantics-agnostic: callers decide how to interpret [status]
    and whether to wake any keeper lane. *)

val set_completion_observer : (completion -> unit) -> unit
(** Install a process-local observer for detached task completion. The observer
    is invoked outside the task-registry mutex. Non-cancel exceptions raised by
    the observer are logged and swallowed so task cleanup cannot be blocked. *)

val reset_completion_observer_for_testing : unit -> unit
(** Restore the default no-op completion observer. Intended for focused tests. *)

val set_lifetime_guard : lifetime_guard -> unit
(** Install a process-wide lifetime guard. The default guard is a no-op. *)

val reset_lifetime_guard_for_testing : unit -> unit
(** Restore the default no-op guard. Intended for focused tests. *)

val set_exit_watcher_thread_create_for_testing : ((unit -> unit) -> unit) -> unit
(** Install a process-local exit watcher thread starter. Intended for focused
    tests that simulate [Thread.create] failure after a detached process has
    spawned. *)

val reset_exit_watcher_thread_create_for_testing : unit -> unit
(** Restore the default [Thread.create]-backed exit watcher starter. *)

val set_sidecar_failure_observer : (site:string -> exn -> unit) -> unit
(** Install the process-local observer for PID sidecar persistence
    failures.  The top-level Otel_metric_store module wires this to
    [masc_bg_task_sidecar_failures_total]; [bg_task] keeps the hook here
    to avoid a lower-library dependency cycle. *)

val set_drain_failure_observer :
  (fd_kind:string -> err_kind:string -> unit) -> unit
(** Install the process-local observer for unexpected (non-EAGAIN /
    EWOULDBLOCK / EINTR / EOF) errors raised by [Unix.read] inside
    [drain_fd_to_buf].  The top-level Otel_metric_store module wires this to
    [masc_bg_task_drain_unexpected_errors_total].

    Labels are closed-vocabulary and cardinality-bounded:
    - [fd_kind] is either ["stdout"] or ["stderr"] (call-site tagged).
    - [err_kind] is either ["unix_error"] (a [Unix.Unix_error] that
      is neither EAGAIN/EWOULDBLOCK nor EINTR — e.g. EBADF, EIO,
      ENOMEM) or ["other"] (any other exception).

    Cancellation ([Eio.Cancel.Cancelled]) is re-raised inside the
    drain loop and never reaches the observer. *)

val reap_orphans : base_path:string -> int
(** Startup hook: read PID files under \`.masc/keeper/*/bg/*.pid\`,
    SIGKILL any pgroup whose leader is no longer in the live task
    map, and delete the stale PID files. Returns the number of
    reaped orphans. *)
