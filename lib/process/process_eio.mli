(** Async process execution helpers for Eio.

    NOTE: This module intentionally exposes argv-based APIs only.
    Avoid shell-based execution (`sh -c`) to prevent injection bugs and
    inconsistent semantics across platforms. *)

(** {1 Global init (call once from main_eio.ml)} *)

(** Native foreground commands own a separate process group through the
    foreground manager. [proc_mgr] supplies pipe plumbing; direct callers of
    that manager (LSP and official clients) retain their own lifecycle. *)
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

    When the owning switch is cancelled, cleanup preserves the full grace
    even if the child closes its output pipes early or both outputs are
    redirected to files. Pipe EOF alone does not establish child exit. The
    switch's foreground process-group owner performs the final kill/reap.

    On the other path, once the grace has run out and the [SIGKILL] is sent,
    the wait for the exit status is bounded by the same number, and only
    happens while the owning switch is still on; a switch that was cancelled
    during the grace gets no wait, its release hook reaps the child. Every
    explicit await in this helper is bounded by this grace; a pipeline
    requests cleanup for its stages in order. *)

(** {1 Observability hook (#9632)} *)

(** Origin at which a [run_argv*] timeout budget was exhausted.

    - [Timeout_origin.Spawn] — timeout fired before [Eio.Process.spawn] returned, i.e.
      process creation itself stalled (docker daemon backpressure, container
      cold start during [docker run]).
    - [Timeout_origin.Command] — timeout fired after the child was created and while
      draining pipes or awaiting exit; the normal “command was slow” case. *)

val process_timeout_observer_fn :
  (program:string -> timeout_sec:float -> origin:Timeout_origin.t -> unit) Atomic.t
(** Hook fired from every [run_argv*] timeout branch.  Default no-op so
    [masc_process] carries no [Otel_metric_store] dependency.  [lib/workspace.ml]
    wires it at module load to emit [masc_process_timeout_total].
    [program] is [Filename.basename argv0] (~10-20 distinct programs fleet-wide);
    [origin] is [Spawn] or [Command], so the metric’s
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

type fallback_policy = Allow_unix_fallback | Eio_only
(** [Eio_only] fails closed if the Eio runtime is unavailable and does not
    retry via Unix after an Eio error. The default preserves Unix fallback. *)

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
  ?fallback_policy:fallback_policy ->
  ?output_capture:Process_output_capture.t ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  stdin_content:string ->
  string list ->
  (Unix.process_status * string * string)
(** Like [run_argv_with_stdin_and_status], but returns
    [(status, stdout, stderr)] without combining stderr into stdout. When
    callback arguments are supplied on the Eio path, they are invoked for
    stdout/stderr chunks while the process is still running. Fallback Unix
    execution remains completion-captured. [Eio_only] also prevents Unix
    execution when no Eio runtime is initialized. *)

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
           Unix fallback applies the same initialized default when available;
           without initialization, relative paths use the parent's directory.
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
type cwd_error =
  | Native_cwd_error of Unix.error
  | Eio_cwd_error of Eio.Exn.err
(** The backend's original directory error, without guessing an executable
    failure from a directory that could not be opened. *)

type spawn_refusal =
  | Empty_argv  (** No program to run. *)
  | Executable_not_found of string
      (** argv[0], as the caller gave it, resolved to no file. Eio's spawner
          does the PATH resolution and raises
          [Eio.Process.Executable_not_found]; the Unix fallback learns the
          same from its group-owning [posix_spawnp] raising [ENOENT] at the spawn. *)
  | Spawn_failed of
      { executable : string
      ; error : Unix.error
      }
      (** A [Unix_error] before the child existed, with its errno: the
          fallback's [posix_spawnp] refusing the program ([EACCES], [E2BIG],
          [ENOEXEC], ...), pipe, fork or capture-file setup failing on
          either path, or the eio path's cwd open failing with an errno eio
          does not map to [Eio.Fs.E] ([ENOTDIR], [ELOOP], [EMFILE], ...). *)
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
      ; error : cwd_error
      }
      (** The requested directory could not be opened before spawn. Both
          execution paths preserve the backend's directory error here. *)

val spawn_refusal_to_string : spawn_refusal -> string

type spawn_outlook =
  | Same_input_fails_again
      (** Spawning the same argv, env and cwd again fails the same way until
          someone changes them or the host. *)
  | Resources_may_free
      (** A shortage the system releases on its own (descriptors, memory,
          process slots, an interrupted call): a later spawn can succeed. *)
  | Cause_unknown
      (** The refusal does not carry a typed cause. [Child_setup_failed] is
          the one case: eio reports the child's fchdir, dup2 or execve errno
          only as text, and execve fails both for a request that cannot pass
          ([E2BIG], [ENOEXEC]) and for a shortage that passes ([ENOMEM],
          [EAGAIN], [ENFILE], [ETXTBSY] while the binary is replaced). The
          text is not parsed, so a caller must not treat this as either
          answer; the keeper records it for an operator instead of
          releasing it as transient. *)

val unix_error_spawn_outlook : Unix.error -> spawn_outlook
val spawn_refusal_outlook : spawn_refusal -> spawn_outlook

val spawn_child :
  sw:Eio.Switch.t ->
  [> 'tag Eio.Process.mgr_ty ] Eio.Resource.t ->
  ?cwd:Eio.Fs.dir_ty Eio.Path.t ->
  ?stdin:_ Eio.Flow.source ->
  ?stdout:_ Eio.Flow.sink ->
  ?stderr:_ Eio.Flow.sink ->
  ?env:string array ->
  string list ->
  ('tag Eio.Process.ty Eio.Resource.t, spawn_refusal) result
(** [Eio.Process.spawn] with every failure that precedes the child returned as
    a {!spawn_refusal}: a cwd open failing with an errno eio does not map to
    [Eio.Fs.E] is a [Spawn_failed] with that errno. Other exceptions,
    cancellation included, propagate. *)

type 'tag piped_child =
  { process : 'tag Eio.Process.ty Eio.Resource.t
  ; to_stdin : [ Eio.Flow.sink_ty | Eio.Resource.close_ty ] Eio.Resource.t
      (** The parent's write end of the child's stdin. *)
  ; from_stdout : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Resource.t
  ; from_stderr : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Resource.t
  }

val spawn_piped_child :
  sw:Eio.Switch.t ->
  [> ([> `Generic ] as 'tag) Eio.Process.mgr_ty ] Eio.Resource.t ->
  ?cwd:Eio.Fs.dir_ty Eio.Path.t ->
  ?env:string array ->
  string list ->
  ('tag piped_child, spawn_refusal) result
(** Three [Eio.Process.pipe]s and {!spawn_child} as one refusal boundary. A
    pipe that cannot be made ([EMFILE], [ENFILE], [ENOMEM]) is a
    [Spawn_failed] with its errno, so its outlook comes from
    {!unix_error_spawn_outlook} like a fork failure's. On [Ok] the child's
    pipe ends are already closed in the parent; every pipe end belongs to
    [sw]. *)

type stdio_refusal =
  | Runtime_unavailable of string
      (** No initialized runtime or no Eio fiber in which to own the child.
          No process is started and there is no Unix fallback. *)
  | Spawn_refused of spawn_refusal
      (** A failure before the child exists, never a callback failure. *)

type stdio_context
(** One captured initialized process runtime: its process manager, default
    cwd capability/path and clock. Reinitialization or reset does not replace
    these values. This borrows their existing lifetime; it neither keeps a
    closed resource alive nor pins the directory named by the path. *)

val capture_stdio_context : unit -> (stdio_context, string) result
(** Capture the initialized runtime once, without spawning or opening a
    directory. [Error] means no runtime is initialized. The capture does not
    establish an active Eio fiber; {!with_stdio} checks that at use time. *)

val stdio_context_clock : stdio_context -> float Eio.Time.clock_ty Eio.Resource.t
(** The clock from that same captured runtime, without rereading global state. *)

val with_stdio :
  ?context:stdio_context ->
  ?env:string array ->
  ?cwd:string ->
  on_stderr_chunk:(string -> unit) ->
  on_stdout_tail:(string -> unit) ->
  string list ->
  (input:Eio.Flow.source_ty Eio.Resource.t ->
   output:Eio.Flow.sink_ty Eio.Resource.t -> 'a) ->
  ('a * Unix.process_status, stdio_refusal) result
(** Own a foreground process group while the callback uses its stdout [input]
    and stdin [output]. The callback borrows both flows and must finish any
    fibers using them before returning. Stderr is drained concurrently and
    delivered unchanged to [on_stderr_chunk].

    After a normal callback return, close stdin, deliver stdout bytes still in
    the pipe to [on_stdout_tail], drain stderr to EOF, and await the actual
    child status. There is no preview truncation, fabricated exit status, or
    internal timeout. The caller owns any timeout and may cancel the call.

    Callback, stream, and cancellation exceptions propagate after the owned
    child/group is released. Stream callback failures are not swallowed.
    Only initialization and pre-child spawn failures return [Error]. The
    process-wide spawn guard and initialized cwd capability are preserved.
    With [context], manager, cwd and clock all come from that capture; without
    it, this call captures the currently initialized runtime. Either form
    refuses outside an active Eio fiber and never falls back to Unix. *)

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
  | Plumbed
      (** the pipe from the stage before; a lone process, or the first stage,
          reads an input already at its end and never this process's stdin *)
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
  ?fallback_policy:fallback_policy ->
  ?output_capture:Process_output_capture.t ->
  on_stdout_chunk:(string -> unit) ->
  on_stderr_chunk:(string -> unit) ->
  string list ->
  (Unix.process_status * string * string)
(** Like [run_argv_with_status_split], but invokes [on_stdout_chunk] and
    [on_stderr_chunk] for every chunk read from the child pipes while the
    process is still running. The returned strings are bounded previews.
    [output_capture], when supplied, preserves raw chunks independently of
    callbacks and marks completeness only at pipe EOF. Unix fallback has no
    authoritative chunk/EOF contract and marks capture unavailable.
    [Eio_only] prevents that fallback entirely. *)

type pipeline_stage = {
  argv : string list;
  env : string array option;
  cwd : string option;
  stdin : input_origin;
  stdout : output_destination;
  stderr : output_destination;
}
(** One process stage in a native pipeline.

    [Plumbed] and [Captured] mean the stage takes the pipeline's own
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

type detached_handle = Process_eio_detached.detached_handle = {
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

type detached_devnull_handle = Process_eio_detached.detached_devnull_handle = {
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
