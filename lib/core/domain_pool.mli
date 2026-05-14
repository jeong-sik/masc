(** Domain_pool — masc-mcp policy layer over [Eio.Executor_pool].

    Wraps [Eio.Executor_pool] with three pieces of policy that the raw
    library leaves up to each caller:

    {ol
    {- A default [domain_count] that reserves one core for the Eio
       scheduler driving HTTP / SSE / fiber dispatch on the main
       domain.}
    {- Named submit variants for IO-bound vs CPU-bound work, fixing
       the [~weight] argument that [Eio.Executor_pool] requires per
       call.  Centralising weight policy here keeps it consistent
       across keeper, dashboard, and repo-sync callers.}
    {- Async ([Promise]-returning) submit variants alongside blocking
       ones, so callers don't have to remember which Eio entry point
       to use for each shape.}}

    PR-6 of RFC-0059 introduces this module as a primitive.  PR-7
    (keeper actor migration) and PR-8 (repo sync async) consume it for
    parallel actor dispatch and parallel git command execution.

    [Executor_pool_ref] (global atomic holder + inline fallback) is
    orthogonal: it serves dashboard compute that must work in tests
    where no pool exists.  [Domain_pool] is for code paths that hold
    an explicit pool handle. *)

type t
(** Opaque pool handle.  Carries the underlying [Eio.Executor_pool.t]
    plus the resolved [domain_count] for telemetry. *)

val recommended_domain_count : unit -> int
(** [max 2 (Domain.recommended_domain_count () - 1)].

    The [-1] reserves the original main domain for the Eio scheduler
    so HTTP listeners, SSE drains, and fiber dispatch don't compete
    with worker domains for OS-thread time.  The floor of [2] keeps
    the default sensible on 1- or 2-core systems where the
    recommendation can be [1]. *)

val create :
  sw:Eio.Switch.t ->
  ?domain_count:int ->
  _ Eio.Domain_manager.t ->
  t
(** [create ~sw ?domain_count dm] spawns worker domains via
    [Eio.Executor_pool.create].

    [domain_count] defaults to {!recommended_domain_count}.  Raises
    [Invalid_argument] if an explicit value is [< 1].

    The pool's lifetime is bound to [sw] — when [sw] finishes, all
    worker domains and in-flight jobs are cancelled (per
    [Eio.Executor_pool] semantics). *)

val domain_count : t -> int
(** Resolved worker count.  Matches the value passed to [create] (or
    {!recommended_domain_count} when omitted). *)

val submit_io : t -> (unit -> 'a) -> 'a
(** Blocking submit for IO-bound work (HTTP calls, disk I/O, network
    syscalls).

    Uses [~weight:0.05], so each worker domain admits ~20
    concurrently-running IO-bound jobs before queueing.  Re-raises
    exceptions thrown by [f]. *)

val submit_cpu : t -> (unit -> 'a) -> 'a
(** Blocking submit for CPU-bound work (JSON encode/decode, hashing,
    text similarity, embedding compute).

    Uses [~weight:1.0], so each worker domain admits one CPU-bound
    job at a time.  Re-raises exceptions thrown by [f]. *)

val submit_io_async :
  sw:Eio.Switch.t -> t -> (unit -> 'a) -> 'a Eio.Promise.or_exn
(** Async variant of {!submit_io}.  Returns immediately with a
    promise the caller awaits via [Eio.Promise.await_exn].  Cancelling
    [sw] cancels the in-flight job. *)

val submit_cpu_async :
  sw:Eio.Switch.t -> t -> (unit -> 'a) -> 'a Eio.Promise.or_exn
(** Async variant of {!submit_cpu}. *)

val executor_pool : t -> Eio.Executor_pool.t
(** Escape hatch for callers that need a non-default [~weight] (e.g.
    a job that occupies half a core, [~weight:0.5]).  Prefer
    {!submit_io} / {!submit_cpu} so the weight policy stays
    centralised here. *)
