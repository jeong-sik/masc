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
(** Return true when an Eio process-spawn exception should retry via the Unix
    fallback path (e.g. bind-related subprocess transport errors on macOS). *)
val should_retry_unix_fallback : exn -> bool

(** {1 Exit reason} *)

type exit_reason =
  | Completed of int
      (** The program ran and returned this code. Never [124] — see
          [Timed_out]. *)
  | Timed_out
      (** The run exceeded its budget and [Process_eio] killed it. The status
          it synthesizes is [Unix.WEXITED 124], following timeout(1), so a
          program that exits 124 on its own is indistinguishable from one that
          was killed. That has been true since this status was introduced; the
          variant names it instead of leaving every caller to compare against
          the number. *)
  | Signaled of int
  | Stopped of int

val exit_reason_of_status : Unix.process_status -> exit_reason
(** Classify a status this module produced.

    Three modules outside this one had come to read [Unix.WEXITED 124]
    directly (repo_git, voice_bridge_core, exec_dispatch), which made the
    number a contract nobody had written down: changing it here would have
    left their arms unreachable with nothing to say so, and a repository whose
    origin lookup timed out would have been skipped from discovery instead of
    aborting it (#28651). *)

val timed_out_status : Unix.process_status
(** The status this module synthesizes for [Timed_out]. Exposed for the tests
    and callers that construct one; classify with [exit_reason_of_status]
    rather than comparing against it. *)

val child_exit_grace_seconds : float
(** How long a child has between SIGTERM and SIGKILL when this module stops
    it, whether because its call timed out, its caller raised, or the switch
    it runs under was cancelled.

    On the cancellation path the wait is for the child to close the pipes
    this side holds, since its exit status cannot be awaited there; a child
    that hands a pipe to a grandchild is waited on until the grandchild lets
    go too, or the grace runs out. A child given no pipe at all -- both
    streams redirected to files -- gets no wait on that path.

    On the other path, once the grace has run out and the [SIGKILL] is sent,
    the wait for the exit status is bounded by the same number, and only
    happens while the owning switch is still on; a switch that was cancelled
    during the grace gets no wait, its release hook reaps the child. Every
    way out of a stopped spawn is therefore bounded by two of these per
    child; a pipeline stops its stages one after another, so its bound is
    two per stage. *)

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

val run_argv_with_stdin_held_open_and_status_split :
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  stdin_content:string ->
  string list ->
  (Unix.process_status * string * string)
(** Like [run_argv_with_stdin_and_status_split], except the child stdin stays
    open after [stdin_content] has been written and closes only after the
    child exits or the enclosing Eio switch is cancelled.

    This is a protocol primitive for peers where EOF means cancellation, not
    merely end-of-request. It requires an initialized Eio process runtime and
    fails closed with status 127 when called through the Unix fallback path. *)

val cwd_path : string option -> (Eio.Fs.dir_ty Eio.Path.t, string) result
(** Resolve an optional [cwd] string against the initialized default.

    Absolute replaces the default, relative appends to it -- the same rule the
    [?cwd:string] entry points above apply, and the same dependence on the
    capability [init] was given. [Error] when [init] has not run. *)

(** Run command with explicit argv, return (Unix.process_status, stdout).
    Uses spawn + await to get exit status without raising.
    @param timeout_sec Optional explicit wall-clock timeout. Absent means unbounded.
    @param env Optional environment (Unix-style ["K=V"; ...]).
    @param cwd Override working directory for the spawned process.
           Absolute paths replace the default cwd; relative paths append to it.
           Both go through the capability [init] was given, so how far an
           absolute path reaches is that capability's business: the binaries
           pass [Eio.Stdenv.fs] and reach anywhere, while a test harness
           passing [Eio.Stdenv.cwd] gets "Capabilities insufficient" outside
           its own root.
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
    [(status, stdout, stderr)] without combining stderr into stdout.

    A failure before the child exists (see {!spawn_refusal}) comes back as
    [Unix.WEXITED 127] with a [process_eio_error:] line in the stderr slot,
    the same shape a program that ran and exited 127 produces. This runner
    and the other tuple runners keep folding it that way for the callers that
    read the tuple; {!run_argv_with_status_split_or_refusal} returns the same
    failure as a value. *)

(** {1 Spawn refusal} *)

(** Everything either spawn path can fail with before a child process exists.
    The set is read from eio 1.3 and OCaml 5.5 sources; the implementation
    cites the lines. *)
type spawn_refusal =
  | Empty_argv  (** No program to run. *)
  | Executable_not_found of string
      (** argv[0], as the caller gave it, resolved to no file. Eio's spawner
          does the PATH resolution and raises
          [Eio.Process.Executable_not_found]; the Unix fallback learns the
          same from [Unix.create_process_env] raising [ENOENT] at the spawn. *)
  | Spawn_failed of
      { executable : string
      ; error : Unix.error
      }
      (** A [Unix_error] before the child existed, with its errno: the
          fallback's [posix_spawnp] refusing the program ([EACCES], [E2BIG],
          [ENOEXEC], ...), or pipe, fork or capture-file setup failing on
          either path. *)
  | Child_setup_failed of
      { executable : string
      ; detail : string
      }
      (** Eio path only: the forked child could not complete its setup
          (fchdir, dup2, execve). eio's fork actions report
          ["<action>: <strerror>"] over a pipe and the parent raises
          [Failure] with that text, so the errno reaches here already as
          text. [detail] is that text, carried, not parsed. *)
  | Cwd_unavailable of
      { cwd : string
      ; error : Eio.Fs.error
      }
      (** Eio path only: the working directory the caller asked for could
          not be opened before the fork ([Not_found], [Permission_denied]).
          The Unix fallback ignores [?cwd], so it never reports this. *)

val spawn_refusal_to_string : spawn_refusal -> string

val run_argv_with_status_split_or_refusal :
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  string list ->
  (Unix.process_status * string * string, spawn_refusal) result
(** {!run_argv_with_status_split} with every failure that happens before a
    process exists returned as a value instead of folded into the status.

    A caller that tries several programs in turn (an image scaler chain, a
    player chain) cannot otherwise say which of them was absent, or refused,
    without reading the synthesized text. [Ok] carries exactly what
    {!run_argv_with_status_split} returns, timeouts included, and no
    [Error] case is ever rendered as an exit status here; the refusal is not
    logged because the caller owns what it means. *)

type output_destination =
  | Captured
      (** today's behaviour: the child writes into a pipe this process drains
          into the returned string *)
  | Written_to of {
      path : string;
      append : bool;
    }
      (** the child writes into the file itself. The bytes never pass through
          this process, so the returned string for that stream is empty and
          the output is not bounded by any capture cap. *)

type input_origin =
  | Inherited  (** the child keeps this process's stdin *)
  | From_string of string  (** feed the child a string this process holds *)
  | Read_from of { path : string }  (** the child reads the file itself *)

val run_argv_with_redirects :
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  stdin:input_origin ->
  stdout:output_destination ->
  stderr:output_destination ->
  string list ->
  (Unix.process_status * string * string, string) result
(** Run [argv] with each standard stream attached to a file or to a capture
    pipe, chosen per stream.

    A file is opened before the spawn, so a path that cannot be opened is
    reported as [Error] and no process runs — the same order a shell uses, and
    the reason the failure is a distinct value rather than an exit status this
    function invented.

    Streams set to [Captured] behave exactly as in
    {!run_argv_with_status_split}. Streams attached to a file return [""].

    @since 2.62.0 *)

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
  stdin : input_origin;
  stdout : output_destination;
  stderr : output_destination;
}
(** One process stage in a native pipeline.

    [Inherited] and [Captured] mean the stage takes the pipeline's own
    plumbing: the pipe from the stage before it, the pipe to the stage after
    it, the stderr this runtime collects. A file replaces that plumbing for
    one stream, which is how a shell reads [a > f | b] -- b's stdin is still
    the link and simply reaches EOF with nothing in it. *)

val plumbed_stage :
  argv:string list -> env:string array option -> cwd:string option -> pipeline_stage
(** A stage whose three streams all follow the pipeline's plumbing. *)

val run_argv_pipeline_with_status_split :
  ?timeout_sec:float ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  pipeline_stage list ->
  (Unix.process_status * string * string, string) result
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
    callers are responsible for [Unix.waitpid] reaping.

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
