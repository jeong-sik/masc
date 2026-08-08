(** Minimal background task wrapper with a waitpid reaper.

    Spawns a detached process via {!Process_eio.spawn_detached} and
    immediately starts a watcher thread that performs a blocking
    [Unix.waitpid] on the leader PID.  This reaps the leader as soon as
    it exits, preventing macOS from keeping a zombie process group
    leader alive and making {!Process_eio.is_pgid_alive} report the
    group as dead once the reaper has run.

    Tick 7: the reaper resolves the grandchild reach issue described in
    [test/test_process_eio_detached.ml]. *)

type t

val spawn :
  argv:string list -> env:string array -> cwd:string -> (t, string) result
(** Fork a detached process and start a waitpid reaper for the leader. *)

val kill : t -> signal:int -> grace_sec:float -> unit
(** Escalating tree-kill on the task's process group. *)

val is_alive : t -> bool
(** True while the process group still has a live member.  After the
    leader has exited and the reaper has reaped it, this becomes false
    (unless a grandchild is still running in the group). *)

val handle : t -> Process_eio.detached_handle
(** Expose the underlying handle so callers can close stdout/stderr FDs. *)
