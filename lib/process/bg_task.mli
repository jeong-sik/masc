(** Background shell task lifecycle — Phase 2 of the Legendary Bash
    roadmap.

    Maps claude-code's [backgroundTaskId] / [BashOutput] / [KillShell]
    triad onto OCaml Unix primitives.

    Tick 6a (current): pull-based.  [read] drains whatever is pending
    on the child's pipes without blocking.  No long-lived fiber, no
    Eio switch — the MCP polling loop IS the drain cadence.  Child
    runs in its own session via {!Process_eio.spawn_detached};
    tree-kill via [Unix.kill (-pgid)] reaches descendants.

    Tick 7 (planned): introduce a daemon switch and push-based
    drainers so slow readers can't stall producers, plus
    append-only backing files under
    \`.masc/keeper/<name>/bg/<id>.{out,err}\` for persistence across
    reader restarts.  That tick will reintroduce a [val init :
    sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> unit] hook
    separately from [spawn] so this signature stays stable. *)

(** Opaque UUID-like handle. Constructible only via [spawn]. *)
type task_id = private string

val task_id_to_string : task_id -> string

(** Rehydrate a task_id from JSON at the MCP boundary without raising. *)
val task_id_of_string : string -> (task_id, string) result

(** Rehydrate a task_id from JSON at the MCP boundary. Raises
    [Invalid_argument] on a syntactically invalid handle — callers must
    be the MCP layer that accepted the string as a tool argument. *)
val task_id_of_string_exn : string -> task_id

type snapshot =
  { stdout_since : string (** Bytes emitted on stdout since [since]. *)
  ; stderr_since : string (** Bytes emitted on stderr since [since]. *)
  ; closed : bool
    (** True once the process has exited. No further bytes will
          arrive after a [closed = true] snapshot. *)
  ; status : Unix.process_status option
    (** Raw process status. Use
          {!Exec_semantic.interpret} in [masc_exec] to turn this into
          a typed classification; bg_task itself stays
          semantics-agnostic to avoid a circular sub-library
          dependency. *)
  ; bytes_dropped_stdout : int
  ; bytes_dropped_stderr : int
    (** Head-drop counters for the ring buffers; non-zero means the
          caller read too late to see every byte. *)
  }

type spawn_error =
  | Spawn_failed of string
  | Too_many_tasks of
      { keeper : string
      ; limit : int
      }
  | Invalid_cwd of string

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
val spawn
  :  ?base_path:string
  -> keeper:string
  -> argv:string list
  -> cwd:string
  -> envp:string array
  -> timeout_sec:float
  -> unit
  -> (task_id, spawn_error) result

type read_error =
  | Unknown_task of task_id
  | Read_failed of string

(** Non-blocking snapshot of the task's output. [since_*] are byte
    offsets into the cumulative stream; the returned [stdout_since]
    contains bytes at offsets [>= since_stdout]. *)
val read
  :  task_id
  -> since_stdout:int
  -> since_stderr:int
  -> (snapshot, read_error) result

type kill_error =
  | Unknown_task_kill of task_id
  | Kill_failed of string

(** Send [signal] to the pgroup; if the process is still alive after
    [grace_sec], escalate to [SIGKILL]. Idempotent on
    already-dead tasks. *)
val kill : task_id -> signal:int -> grace_sec:float -> (unit, kill_error) result

(** All currently-tracked tasks owned by [keeper]. *)
val list : keeper:string -> task_id list

(** Same roster as {!list}, paired with the unix-timestamp at which
    each task was spawned.  The timestamp is captured by
    {!Process_eio.spawn_detached} before the child enters its session
    and is immutable for the task's lifetime, so observers can compute
    wall-clock elapsed time without consulting the child process or
    reading the PID file. *)
val list_with_started_at : keeper:string -> (task_id * float) list

(** Startup hook: read PID files under \`.masc/keeper/*/bg/*.pid\`,
    SIGKILL any pgroup whose leader is no longer in the live task
    map, and delete the stale PID files. Returns the number of
    reaped orphans. *)
val reap_orphans : base_path:string -> int
