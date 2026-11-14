(** An [Eio_unix.Process] manager that starts children with posix_spawn(2).

    eio_posix starts children with fork(), and on macOS the parent side of a
    fork locks every malloc zone; with masc's 1-2 GB heap that held the main
    domain about 141 ms per spawn (2026-09-05 stack samples, RFC
    main-domain-scheduler-latency §8.8). posix_spawn runs no atfork handler.

    The manager accepts the same arguments as the eio_posix one: [cwd] (a
    native path), [env], [stdin]/[stdout]/[stderr] and, through
    [Eio_unix.Process.spawn_unix], any descriptor map. Children are awaited
    through [Eio_unix.Process.sigchld]; only a backend that installs a SIGCHLD
    handler broadcasts it, and eio_linux installs none, so the manager
    installs one itself when a spawn finds none
    ({!Posix_spawn_detached.ensure_sigchld_handler}). Children are killed and reaped when
    their switch is cancelled or released. Cancellation settles the original
    process handle before its reaper exits, including when a caller is already
    awaiting it under cancellation protection. Reaper failure is propagated to
    waiters separately from physical exit; it cannot confirm child cleanup. A spawn failure raises
    [Unix.Unix_error (errno, "posix_spawn", executable)]; the executable
    lookup on PATH and its [Eio.Io] error stay with [Eio_unix.Process]. *)

exception Stop_without_grace
(** A cancellation reason that ends a child at once. When the cancellation
    that reaches a child's reaper carries this reason, directly or inside
    [Eio.Cancel.Cancelled], [Fun.Finally_raised] or an [Eio.Exn.Multiple]
    whose members all carry it, the reaper sends SIGKILL to the child or its
    group with no TERM grace. Any other cancellation stops the child as
    before, and a stop already under way keeps its grace. Server shutdown
    fails running Keeper turns with it, and the Keeper records a turn that
    ends with it as stopped by a restart. Fail a switch with it only for work
    that shutdown abandons. *)

val mgr : Eio_unix.Process.mgr_ty Eio.Resource.t

val original_start : _ Eio.Process.t -> string option
(** Kernel birth token captured immediately after the original spawn, before
    observers or the reaper can release its PID. Reading this value never looks
    up a PID again; it remains the original observation after exit/reap.
    [None] means the manager does not provide this observation, or the original
    child's birth could not be observed. It must not authorize a fresh lookup
    as a replacement for the original identity. *)

val foreground_mgr :
  clock:_ Eio.Time.clock -> grace_seconds:float ->
  Eio_unix.Process.mgr_ty Eio.Resource.t
(** Owns each foreground process group until cleanup, then promptly reaps
    its leader. TERM grants the supplied grace while any group member is
    alive, even after the leader has exited; once the leader has exited and no
    member is alive, the leader is reaped without waiting out the rest.
    Ordinary completion cleans up remaining group members without that delay.
    Children that deliberately leave the group are outside this contract. *)

module For_testing : sig
  val foreground_mgr :
    clock:_ Eio.Time.clock -> grace_seconds:float ->
    waitpid:(int -> int * Unix.process_status) ->
    Eio_unix.Process.mgr_ty Eio.Resource.t
  (** Inject the final blocking reap operation while retaining real spawn, exit
      observation, group signalling and owner synchronization. *)
end
