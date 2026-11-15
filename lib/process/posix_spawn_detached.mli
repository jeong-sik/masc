(** A child that outlives the switch it was started on.

    It is started with posix_spawn(2), as {!Posix_spawn_process_mgr} starts
    its children, so a server running several domains can start it (fork(2)
    is refused there, which rules out {!Process_eio_detached}). It runs in a
    process group of its own (not a session of its own), reads [/dev/null]
    and writes [output] on both stdout and stderr. Nothing stops it on its
    own: when [sw] is released this process only stops waiting for it, and
    once this process has exited the child is reaped by whoever adopts it. *)

type t = {
  pid : int;  (** Also the child's process group. *)
  started : string option;
      (** When the child started ({!process_start}), read before anything
          here could reap it, so the number was still the child's. *)
  exited : Unix.process_status option Eio.Promise.t;
      (** Resolved when the child is reaped while [sw] is still on; never
          resolved after [sw] is released. [None] when another waiter in this
          process reaped it first, so its status is not known here. *)
}

(** [argv]'s first element is the executable's path, used as given: no PATH
    lookup. [output] may be any descriptor, standard ones included. [Error]
    names the call that failed, what it failed on and why: posix_spawn and
    the executable, or openfile and [/dev/null]. *)
val spawn :
  sw:Eio.Switch.t ->
  argv:string list ->
  env:string array ->
  output:Unix.file_descr ->
  (t, string) result

(** Installs the handler that broadcasts [Eio_unix.Process.sigchld] when
    SIGCHLD has no handler in this process, and writes nothing when it has
    one. A spawn whose reaper waits on that condition calls it before the
    child can exit. Calls from several domains install at most once. A
    handler that does not broadcast the condition is left in place, and a
    reaper then waits for one that does. *)
val ensure_sigchld_handler : unit -> unit

(** Whether a process is left in the group numbered [group]: a child's own
    children stay in its group unless they leave it. [false] for 0 and 1,
    which kill(2) reads as this process's own group and as every process, so
    neither is ever probed. A group whose processes another account owns is
    there, whether or not this process may signal it. Darwin answers EPERM for
    a group whose members are all exiting or zombies, which reads as none left
    (see {!Process_group_members}). *)
val group_id_has_members : int -> bool

(** When the process numbered [pid] started, as a token no later process
    given that number shares: Darwin's p_starttime to the microsecond, from
    the kernel's process table; Linux's boot id and /proc starttime. A child
    not yet reaped still reads. [None] when no such process is there, or
    the platform gives neither. It starts no process, so it never yields. *)
val process_start : int -> string option
