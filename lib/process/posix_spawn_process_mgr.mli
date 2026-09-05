(** An [Eio_unix.Process] manager that starts children with posix_spawn(2).

    eio_posix starts children with fork(), and on macOS the parent side of a
    fork locks every malloc zone; with masc's 1-2 GB heap that held the main
    domain about 141 ms per spawn (2026-09-05 stack samples, RFC
    main-domain-scheduler-latency §8.8). posix_spawn runs no atfork handler.

    The manager accepts the same arguments as the eio_posix one: [cwd] (a
    native path), [env], [stdin]/[stdout]/[stderr] and, through
    [Eio_unix.Process.spawn_unix], any descriptor map. Children are awaited
    through [Eio_unix.Process.sigchld], which eio_posix installs, and are
    killed and reaped when their switch is released. A spawn failure raises
    [Unix.Unix_error (errno, "posix_spawn", executable)]; the executable
    lookup on PATH and its [Eio.Io] error stay with [Eio_unix.Process]. *)

val mgr : Eio_unix.Process.mgr_ty Eio.Resource.t
