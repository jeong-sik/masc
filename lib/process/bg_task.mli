(** Background shell task lifecycle — Phase 2 of the Legendary Bash
    roadmap.

    Maps claude-code's [backgroundTaskId] / [BashOutput] / [KillShell]
    triad onto OCaml/Eio primitives:
    - [Eio.Switch] per task gives type-safe cancellation propagation;
      every child fiber and every spawned process lives inside the
      switch's scope, so a [cancel] transitively tears them down.
    - pgid-based tree-kill (via [Unix.setpgid] in the child and
      [Unix.kill (-pgid)] in the parent) reaches grandchildren that a
      naïve [Unix.kill pid] would leak.
    - Append-only backing files on disk (\`.masc/keeper/<name>/bg/<id>.out\`
      / [.err]) avoid the JS [StreamWrapper] model — readers [Read]
      against a ring-buffer view with a [bytes_dropped] counter.

    Implementation arrives in Tick 5. This mli is the contract so
    downstream modules (tool_shard, keeper_exec_shell) can start
    depending on the types in parallel. *)

type task_id = private string
(** Opaque UUID-like handle. Constructible only via [spawn]. *)

val task_id_to_string : task_id -> string

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
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  keeper:string ->
  argv:string list ->
  cwd:string ->
  envp:string array ->
  timeout_sec:float ->
  (task_id, spawn_error) result
(** Fork a long-lived shell task, attach it to [sw]. The task keeps
    running until it exits, [timeout_sec] elapses (SIGTERM -> grace ->
    SIGKILL), or the switch is cancelled. The underlying process
    starts in its own process group; tree-kill addresses
    [-pgid]. Output is tee'd to the backing files and to the in-memory
    ring buffers. *)

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

val reap_orphans : base_path:string -> int
(** Startup hook: read PID files under \`.masc/keeper/*/bg/*.pid\`,
    SIGKILL any pgroup whose leader is no longer in the live task
    map, and delete the stale PID files. Returns the number of
    reaped orphans. *)
