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
    installs one itself on each spawn. Children are killed and reaped when
    their switch is released. A spawn failure raises
    [Unix.Unix_error (errno, "posix_spawn", executable)]; the executable
    lookup on PATH and its [Eio.Io] error stay with [Eio_unix.Process].

    Unlike the eio_posix manager, both managers start each child in a session
    of its own. The child has no controlling terminal: opening /dev/tty fails
    with ENXIO, and a terminal passed as its stdin is replaced by /dev/null.
    A child that tries to prompt fails instead of stopping the process group
    of a parent that runs as a background job of a terminal. What a terminal
    sends its foreground group, Ctrl+C or a hangup, reaches the parent only;
    the manager ends a child when its switch is released. *)

val mgr : Eio_unix.Process.mgr_ty Eio.Resource.t

val foreground_mgr :
  clock:_ Eio.Time.clock -> grace_seconds:float ->
  Eio_unix.Process.mgr_ty Eio.Resource.t
(** Owns each child's process group until cleanup, then promptly reaps
    its leader. TERM grants the supplied grace even if the leader exits first.
    Ordinary completion cleans up remaining group members without that delay.
    Children that deliberately leave the group are outside this contract. *)
