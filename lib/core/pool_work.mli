(** Pool_work — a compute together with the kind of work it does.

    The caller that writes a compute knows whether it mostly waits on I/O or
    keeps a core busy, so it declares that once, when it builds the work.
    Code that receives the work ([Dashboard_cache] and the HTTP wrappers that
    forward into it) submits it with that kind's weight and has no weight of
    its own to choose. A submit nested inside a pool job runs in place
    ({!Executor_pool_ref.in_worker_context}), so a weight chosen anywhere but
    the outermost submit has no effect (RFC-0474 L4b).

    The type is abstract: {!cpu} and {!io} are the only constructors, so a
    compute cannot reach the pool without a declared kind. *)

type kind =
  | Cpu  (** Parsing, hashing, encoding: the job keeps a core busy. *)
  | Io  (** The job mostly waits on an Eio effect (a promise, a systhread). *)

type 'a t

val cpu : name:string -> (unit -> 'a) -> 'a t
(** Work that holds a whole worker while it runs. [name] names it in
    {!Pool_wait} and the trace; callers pass [__FUNCTION__] (RFC-0474 L4c). *)

val io : name:string -> (unit -> 'a) -> 'a t
(** Work that shares a worker with other I/O jobs while it waits on an Eio
    effect. Work that blocks the domain for long without one (a large Stdlib
    channel read and its parse) stops every job the worker admitted beside
    it; declare such a compute [cpu]. *)

val wrap : 'a t -> ((unit -> 'a) -> 'b) -> 'b t
(** [wrap w f] is work of [w]'s kind and name whose body is [f] applied to
    [w]'s body.
    [f] decides whether and when that body runs. Code that adds bookkeeping
    around a compute uses it to keep the caller's declaration. *)

val submit : 'a t -> 'a
(** {!Executor_pool_ref.submit_or_inline} with {!Domain_pool.weight_cpu} for
    {!cpu} work and {!Domain_pool.weight_io} for {!io} work: the body
    runs once, on a worker of the pool the caller's lane selects, or in place
    when there is no pool, outside Eio, or already inside a pool job. *)
