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

(** {1 Eio-native process execution (global refs)} *)

(** Run command with explicit argv (no shell). Safe from injection.
    @param timeout_sec Timeout in seconds (default: 60.0)
    @param env Optional environment (Unix-style ["K=V"; ...]).
    @since 2.45.0 *)
val run_argv : ?timeout_sec:float -> ?env:string array -> string list -> string

(** Run command with explicit argv and stdin input (no shell).
    @param timeout_sec Timeout in seconds (default: 60.0)
    @param env Optional environment (Unix-style ["K=V"; ...]).
    @param stdin_content Body piped to process stdin
    @since 2.45.0 *)
val run_argv_with_stdin : ?timeout_sec:float -> ?env:string array -> stdin_content:string -> string list -> string

(** Run command with explicit argv and stdin input (no shell), return (Unix.process_status, stdout).
    Uses spawn + await to get exit status without raising.
    @param timeout_sec Timeout in seconds (default: 60.0)
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
  stdin_content:string ->
  string list ->
  (Unix.process_status * string * string)
(** Like [run_argv_with_stdin_and_status], but returns
    [(status, stdout, stderr)] without combining stderr into stdout. *)

(** Run command with explicit argv, return (Unix.process_status, stdout).
    Uses spawn + await to get exit status without raising.
    @param timeout_sec Timeout in seconds (default: 60.0)
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

(** {1 Detached (background) spawn primitives — P2 foundation} *)

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
