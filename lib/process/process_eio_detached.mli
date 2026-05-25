(** Detached (background) spawn primitives — P2 foundation

    Extracted from [process_eio.ml] during godfile decomposition.

    @since God file decomposition *)

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
