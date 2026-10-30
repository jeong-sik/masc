(** A domain that starts system threads for callers whose own domain must not
    hold the work.

    [Eio_unix.run_in_systhread] starts the thread on the caller's domain, and
    only one thread of a domain runs OCaml at a time. Called from the main
    domain, a closure that parses, hashes or encodes keeps HTTP accept and
    every request handler waiting for the domain lock until it yields. The
    host domain does nothing else, so its threads wait only for each other. *)

exception Host_failed of exn
(** Raised to a caller whose work the host had already taken when the host's
    scheduler failed. The work may or may not have run. *)

val domain_count : int
(** Domains {!start} adds to the process: 1. *)

val start : unit -> unit
(** Spawn the host domain, once per process; later calls do nothing. The
    domain belongs to no switch and lives until the process exits, so a
    caller still running at shutdown, inside [Eio.Cancel.protect], is served.
    It adds one domain to the process. *)

val run : ?label:string -> (unit -> 'a) -> 'a
(** Run blocking work outside Eio on a system thread, as
    [Eio_unix.run_in_systhread] does, choosing the thread's domain:

    - an Eio fiber that is not masc pool work, with the host running: a
      thread of the host domain;
    - masc pool work ({!Executor_pool_ref.in_worker_context}): a thread of its
      own domain, so pool domains keep running such work in parallel. Pools
      that do not mark their jobs (Agent Core's codec pool, the snapshot
      codec) count as ordinary callers;
    - the host not started, or failed: the caller's domain;
    - a caller outside Eio: [work ()] directly.

    Nothing bounds the calls: each is handed to the host at once, and the host
    gives each its own fiber and thread as soon as it takes it.

    Cancellation is as under [Eio_unix.run_in_systhread]: a caller already
    cancelled does not hand the work over, and once handed over the caller
    waits for it uncancellably and gets its result. Exceptions re-raise with
    their backtrace; the work is never re-run.

    If the host fails, the failure is logged once. Work it had not taken runs
    on the caller's domain instead; work it had taken ends with
    {!Host_failed}. Later calls use the caller's domain.

    The work must not depend on which domain runs it: code that compares the
    current domain with an owner domain ([Eio_context.run_on_owner_domain])
    sees the host, not the caller's domain. *)
