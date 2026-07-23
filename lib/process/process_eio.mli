(** Async process execution helpers for Eio.

    NOTE: This module intentionally exposes argv-based APIs only.
    Avoid shell-based execution (`sh -c`) to prevent injection bugs and
    inconsistent semantics across platforms. *)

(** {1 Global init (call once from main_eio.ml)} *)

val init :
  cwd_default:Eio.Fs.dir_ty Eio.Path.t ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit

val is_initialized : unit -> bool
val reset_for_testing : unit -> unit

val get_proc_mgr : unit -> (Eio_unix.Process.mgr_ty Eio.Resource.t, string) result
val get_clock : unit -> (float Eio.Time.clock_ty Eio.Resource.t, string) result
val get_cwd_default : unit -> (Eio.Fs.dir_ty Eio.Path.t, string) result

(** Return true when an Eio process-spawn exception should retry via the Unix
    fallback path (e.g. bind-related subprocess transport errors on macOS). *)
val should_retry_unix_fallback : exn -> bool

(** {1 Observability hook (#9632)} *)

(** Origin at which a [run_argv*] timeout budget was exhausted.

    - [Timeout_origin.Slot_wait] — retained only for decoding historical
      telemetry. Current process execution has no pre-admission slot wait and
      [Process_eio] never emits it.
    - [Timeout_origin.Spawn] — timeout fired before [Eio.Process.spawn] returned, i.e.
      process creation itself stalled (docker daemon backpressure, container
      cold start during [docker run]).
    - [Timeout_origin.Command] — timeout fired after the child was created and while
      draining pipes or awaiting exit; the normal “command was slow” case.

    The closed vocabulary lives in [Timeout_origin] so process timeouts,
    LLM timeouts, dashboard refreshes, and health probes cannot drift into
    separate stringly vocabularies. *)

val process_timeout_observer_fn :
  (program:string -> timeout_sec:float -> origin:Timeout_origin.t -> unit) Atomic.t
(** Hook fired from every [run_argv*] timeout branch.  Default no-op so
    [masc_process] carries no [Otel_metric_store] dependency.  [lib/workspace.ml]
    wires it at module load to emit [masc_process_timeout_total].
    [program] is [Filename.basename argv0] (~10-20 distinct programs fleet-wide);
    [origin] is one of {!Timeout_origin.process_origins}, so the metric’s
    total cardinality stays bounded by [program × bucket × origin]. *)

val argv_program : string list -> string
(** [argv_program argv] returns [Filename.basename argv0] (or
    ["<empty>"] for an empty argv).  Exposed for tests and parity with
    the hook payload. *)

(** {1 Spawn guard hook} *)

type spawn_guard = { run : 'a. (unit -> 'a) -> 'a }
(** Process-wide wrapper around foreground [run_argv*] subprocess calls.
    The default guard runs the callback immediately. Higher-level runtimes can
    install resource observation without making this lower
    [masc_process] library depend on those policy modules. *)

val set_spawn_guard : spawn_guard -> unit
(** Install the process-wide foreground spawn guard. *)

val reset_spawn_guard_for_testing : unit -> unit
(** Restore the default no-op foreground spawn guard. *)

(** {1 Eio-native process execution (global refs)} *)

(** Every [?timeout_sec] below is an explicit caller boundary. When omitted,
    process execution is unbounded but remains subject to Eio cancellation.
    A non-finite or non-positive explicit value raises [Invalid_argument]
    before spawning a child. *)

(** Run command with explicit argv (no shell). Safe from injection.
    @param timeout_sec Optional explicit wall-clock timeout. Absent means unbounded.
    @param env Optional environment (Unix-style ["K=V"; ...]).
    @since 2.45.0 *)
val run_argv : ?timeout_sec:float -> ?env:string array -> string list -> string

(** Run command with explicit argv and stdin input (no shell).
    @param timeout_sec Optional explicit wall-clock timeout. Absent means unbounded.
    @param env Optional environment (Unix-style ["K=V"; ...]).
    @param stdin_content Body piped to process stdin
    @since 2.45.0 *)
val run_argv_with_stdin : ?timeout_sec:float -> ?env:string array -> stdin_content:string -> string list -> string

(** Run command with explicit argv and stdin input (no shell), return (Unix.process_status, stdout).
    Uses spawn + await to get exit status without raising.
    @param timeout_sec Optional explicit wall-clock timeout. Absent means unbounded.
    @param env Optional environment (Unix-style ["K=V"; ...]).
    @param stdin_content Body piped to process stdin *)
val run_argv_with_stdin_and_status :
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  stdin_content:string ->
  string list ->
  (Unix.process_status * string)

val run_argv_with_stdin_and_status_split :
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  stdin_content:string ->
  string list ->
  (Unix.process_status * string * string)
(** Like [run_argv_with_stdin_and_status], but returns
    [(status, stdout, stderr)] without combining stderr into stdout. When
    callback arguments are supplied on the Eio path, they are invoked for
    stdout/stderr chunks while the process is still running. Fallback Unix
    execution remains completion-captured. *)

(** Run command with explicit argv, return (Unix.process_status, stdout).
    Uses spawn + await to get exit status without raising.
    @param timeout_sec Optional explicit wall-clock timeout. Absent means unbounded.
    @param env Optional environment (Unix-style ["K=V"; ...]).
    @param cwd Override working directory for the spawned process.
           Absolute paths replace the default cwd; relative paths append to it.
           Ignored when falling back to Unix process execution.
    @since 2.45.0 *)
val run_argv_with_status : ?timeout_sec:float -> ?env:string array -> ?cwd:string -> string list -> (Unix.process_status * string)

val run_argv_with_status_split :
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  string list ->
  (Unix.process_status * string * string)
(** Like [run_argv_with_status], but returns
    [(status, stdout, stderr)] without combining stderr into stdout. *)

val run_argv_with_status_split_streaming :
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  on_stdout_chunk:(string -> unit) ->
  on_stderr_chunk:(string -> unit) ->
  string list ->
  (Unix.process_status * string * string)
(** Like [run_argv_with_status_split], but invokes [on_stdout_chunk] and
    [on_stderr_chunk] for every chunk read from the child pipes while the
    process is still running. The returned strings still contain the full
    captured output. *)

type pipeline_stage = {
  argv : string list;
  env : string array option;
  cwd : string option;
}
(** One argv-only process stage in a native pipeline. *)

val run_argv_pipeline_with_status_split :
  ?timeout_sec:float ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  pipeline_stage list ->
  (Unix.process_status * string * string)
(** Run host stages as a native pipeline. Adjacent stages are connected with
    process pipes so intermediate stdout is streamed with backpressure rather
    than buffered into OCaml strings. The returned stdout is the final stage's
    stdout; stderr is captured from every stage in stage order. When callback
    arguments are supplied on the Eio path, they are invoked for chunks read
    from the final stdout pipe and per-stage stderr pipes while the pipeline is
    still running. *)

type detached_handle = {
  pid : int;
      (** Child process PID (also the process-group leader). *)
  pgid : int;
      (** Process group ID; always equal to [pid] for tree-kill. *)
  stdout_fd : Unix.file_descr;
      (** Read end of child's stdout pipe. Caller owns and must close. *)
  stderr_fd : Unix.file_descr;
      (** Read end of child's stderr pipe. Caller owns and must close. *)
  started_at : float;
      (** [Unix.gettimeofday ()] at spawn time. *)
}

type detached_devnull_handle = {
  devnull_pid : int;
      (** Child process PID (also the process-group leader). *)
  devnull_pgid : int;
      (** Process group ID; always equal to [pid] for tree-kill. *)
  devnull_started_at : float;
      (** [Unix.gettimeofday ()] at spawn time. *)
}

val spawn_detached :
  argv:string list ->
  env:string array ->
  cwd:string ->
  (detached_handle, string) result
(** Fork a child in its own process group and return immediately with
    a handle containing PID, PGID, and the caller-owned read ends of
    stdout/stderr. The child runs until it exits or is signaled — it
    does NOT die with the current Eio switch.

    Tree-kill: [Unix.kill (-handle.pgid) signal] reaches every
    descendant (grandchildren included). Use {!tree_kill} for the
    SIGTERM → grace → SIGKILL sequence.

    Bypasses the [proc_mgr] so the child is not tracked by Eio;
    callers are responsible for [Unix.waitpid] reaping (directly or
    via a long-lived daemon fiber in [Bg_task]).

    The argv-only API is intentional: no shell interpolation,
    matching the rest of this module. *)

val spawn_detached_devnull :
  argv:string list ->
  env:string array ->
  cwd:string ->
  (detached_devnull_handle, string) result
(** Like {!spawn_detached}, but redirects stdin/stdout/stderr to [/dev/null]
    and returns no pipe FDs. Use this for fire-and-forget process starts where
    retaining stdout/stderr pipes would either leak descriptors or backpressure
    the child. *)

val tree_kill :
  pgid:int ->
  signal:int ->
  grace_sec:float ->
  unit
(** Escalating tree-kill. Signals the process group [-pgid] with
    [signal]; after [grace_sec], if any member survives, escalates to
    SIGKILL. Idempotent — safe to call on already-dead groups. *)

val is_pgid_alive : pgid:int -> bool
(** True when [-pgid] responds to signal 0, i.e. at least one member
    of the group is still alive. *)
