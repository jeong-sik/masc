(** The domain the TUI's request/response HTTP runs on.

    The TUI draws on its main domain, and a frame can cost more than the
    16 ms the render schedule gives it. Once a frame is due every pass, the
    main loop asks the terminal for keys with a zero timeout and then yields,
    so a request issued from that domain advances one step per pass. Measured
    2026-10-16 with [masc-http-probe --frame-due] against the live server, at
    20 ms of work per pass:

    {v
    answer                          caller's domain   this domain
    /keepers/asks (87 B)            321-602 ms        20 ms
    /dashboard/goals (161 KB)       1223-1504 ms      20 ms
    /keepers/.../chat/history       timed out at 10 s 20-80 ms
      (1.66 MB)
    v}

    Here a request never waits for a pass: it runs on a scheduler that does
    nothing else, and its caller resumes at the main loop's next one.

    Streamed responses stay on the caller's domain. Their chunk consumer is
    TUI state, and every stream the TUI opens is paced by people or by a
    model: an observer feed, a login, a keeper's reply. *)

type t

val start : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> t
(** [start ~sw ~env] spawns the domain, with its own Eio scheduler and its own
    connection pool. It lives as long as [sw]: finishing [sw] cancels the work
    still running there. A domain that fails fails [sw]. *)

val run : t -> (unit -> 'a) -> 'a
(** [run t work] runs [work] on [t]'s domain and returns its result on the
    calling fiber. An exception from [work] is raised here, with its
    backtrace. Cancelling the calling fiber cancels [work].

    [work] must not touch state the caller's domain owns: a switch, an
    [Eio.Mutex] it holds, a value it mutates. Pass it what it needs. *)
