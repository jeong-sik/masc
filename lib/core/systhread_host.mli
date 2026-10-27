(** A domain that starts system threads for callers whose own domain must not
    hold the work.

    [Eio_unix.run_in_systhread] starts the thread on the caller's domain, and
    only one thread of a domain runs OCaml at a time. Called from the main
    domain, a closure that parses, hashes or encodes keeps HTTP accept and
    every request handler waiting for the domain lock until it yields. The
    host domain does nothing else, so its threads wait only for each other. *)

val start : unit -> unit
(** Spawn the host domain, once per process; later calls do nothing. The
    domain belongs to no switch and lives until the process exits, so a
    caller still running at shutdown, inside [Eio.Cancel.protect], is served.
    It adds one domain to the process. *)

val run : ?label:string -> (unit -> 'a) -> 'a
(** Run blocking work outside Eio on a system thread, as
    [Eio_unix.run_in_systhread] does, choosing the thread's domain:

    - an Eio fiber that is not pool work, with the host started: a thread of
      the host domain;
    - pool work ({!Executor_pool_ref.in_worker_context}): a thread of its own
      domain, so pool domains keep running such work in parallel;
    - the host not started (tests, single-domain tools): the caller's domain;
    - a caller outside Eio: [work ()] directly.

    Cancellation is as under [Eio_unix.run_in_systhread]: a caller already
    cancelled does not start the work, and once the work has started the
    caller waits for it and gets its result. There is no queue: a thread
    starts at once, as many as there are calls. Exceptions re-raise with
    their backtrace; the work is never re-run. *)
