(** A domain that starts system threads for callers whose own domain must not
    hold the work.

    [Eio_unix.run_in_systhread] starts the thread on the caller's domain, and
    only one thread of a domain runs OCaml at a time. Called from the main
    domain, a closure that parses, hashes or encodes keeps HTTP accept and
    every request handler waiting for the domain lock until it yields; a
    closure that only makes a syscall still takes that lock to hand its result
    back, and the main domain waits whenever the OS deschedules it there. The
    host domain does nothing else, so its threads wait only for each other.

    This library sits below the code that knows about logging and executor
    pools, so {!start} is told what it needs from them. *)

exception Host_failed of exn
(** Raised to a caller whose work the host had already taken when the host's
    scheduler failed. The work may or may not have run. *)

val domain_count : int
(** Domains {!start} adds to the process: 1. *)

val start
  :  on_domain_start:(unit -> unit)
  -> on_failure:(exn -> unit)
  -> keeps_own_domain:(unit -> bool)
  -> unit
  -> unit
(** Spawn the host domain, once per process; later calls do nothing and their
    arguments are dropped. The domain belongs to no switch and lives until
    the process exits, so a caller still running at shutdown, inside
    [Eio.Cancel.protect], is served. It adds one domain to the process.

    - [on_domain_start] runs first on the host domain.
    - [on_failure] is called once if the host fails, on whichever thread saw
      the failure.
    - [keeps_own_domain] is asked on the caller's fiber by every {!run}:
      [true] keeps that call's thread on the caller's domain. *)

val run : ?label:string -> (unit -> 'a) -> 'a
(** Run blocking work outside Eio on a system thread, as
    [Eio_unix.run_in_systhread] does, choosing the thread's domain:

    - an Eio fiber, with the host running and [keeps_own_domain ()] false: a
      thread of the host domain;
    - an Eio fiber for which [keeps_own_domain ()] is true: a thread of its
      own domain;
    - the host not started, or failed: the caller's domain;
    - a caller outside Eio: [work ()] directly.

    Nothing bounds the calls: each is handed to the host at once, and the host
    gives each its own fiber and thread as soon as it takes it.

    Cancellation is as under [Eio_unix.run_in_systhread]: a caller already
    cancelled does not hand the work over, and once handed over the caller
    waits for it uncancellably and gets its result. Exceptions re-raise with
    their backtrace; the work is never re-run.

    If the host fails, work it had not taken runs on the caller's domain
    instead; work it had taken ends with {!Host_failed}. Later calls use the
    caller's domain.

    The work must not depend on which domain runs it: code that reads
    [Domain.self] or domain-local state sees the host, not the caller's
    domain. *)
