(** Domain_pool — masc policy layer over [Eio.Executor_pool].

    Wraps [Eio.Executor_pool] with three pieces of policy that the raw
    library leaves up to each caller:

    {ol
    {- A default [domain_count] that always leaves the main Eio scheduler
       domain outside the worker pool and, when host capacity allows,
       leaves one additional spare domain for HTTP / SSE / keeper dispatch
       under host pressure.}
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

    [Domain_pool_ref] installs the process-wide instance for runtime
    call sites that need a shared pool with inline fallback. *)

type t
(** Opaque pool handle.  Carries the underlying [Eio.Executor_pool.t]
    plus the resolved [domain_count] for telemetry. *)

val recommended_domain_count : unit -> int
(** [max 1 (Domain.recommended_domain_count () - 2)].

    The [-2] keeps the original main domain outside the executor pool
    and, when available, leaves one additional domain of host scheduling
    headroom, so HTTP listeners, SSE drains, keeper dispatch, and response
    finalisation are not competing with a pool that claims every recommended
    domain.  The floor of [1] preserves a usable executor on small systems,
    where the extra headroom domain may not exist. *)

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

val weight_io : float
(** [0.05]: the weight {!submit_io} gives a job. *)

val weight_cpu : float
(** [1.0]: the weight {!submit_cpu} gives a job. *)

val submit_io : name:string -> t -> (unit -> 'a) -> 'a
(** Blocking submit for IO-bound work (HTTP calls, disk I/O, network
    syscalls). [name] names the work in {!Pool_wait} and the trace
    (callers pass [__FUNCTION__]; RFC-0474 L4c).

    Uses [~weight:0.05], so each worker domain admits ~20
    concurrently-running IO-bound jobs before queueing. Re-raises exceptions
    thrown by [f], without retrying or running [f] on the caller.

    Cancellation of this call is relayed to its worker invocation. If it
    wins before worker entry, [f] is not invoked. Once the worker has entered,
    the caller waits for that invocation's cancellation/cleanup to settle
    before re-raising its original cancellation. This is cooperative: CPU
    work, blocking system calls and protected cleanup may delay settlement.
    Other submissions and the pool remain independent. *)

val submit_cpu : name:string -> t -> (unit -> 'a) -> 'a
(** Blocking submit for CPU-bound work (JSON encode/decode, hashing,
    text similarity, embedding compute).

    Uses [~weight:1.0], so each worker domain admits one CPU-bound
    job at a time. Same cancellation and no-retry contract as {!submit_io}.
    A CPU loop must reach an Eio cancellation point to stop early. *)

val submit_io_async :
  sw:Eio.Switch.t -> name:string -> t -> (unit -> 'a) -> 'a Eio.Promise.or_exn
(** Async variant of {!submit_io}. Returns immediately with a promise.
    [sw] owns the submitting fiber: cancelling [sw] relays cancellation to
    accepted work and waits for entered worker cleanup under the same
    contract as {!submit_io}. Cancelling a separate fiber that merely
    awaits this promise does not cancel the submission owned by [sw]. *)

val submit_cpu_async :
  sw:Eio.Switch.t -> name:string -> t -> (unit -> 'a) -> 'a Eio.Promise.or_exn
(** Async variant of {!submit_cpu}. *)

val executor_pool : t -> Eio.Executor_pool.t
(** Raw escape hatch for callers that need a non-default [~weight] (e.g.
    a job that occupies half a core, [~weight:0.5]).  Prefer
    {!submit_io} / {!submit_cpu} so weight and per-submission cancellation
    stay centralised here. Raw Eio submissions do not use this module's
    worker cancellation/settlement bridge. *)
