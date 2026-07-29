(** Per-owner synchronization for durable Keeper event queues.

    One owner is identified by the canonical MASC [base_path] and a parsed
    {!Keeper_id.Keeper_name}.  The process-wide ephemeron registry mutex
    protects only owner lookup/creation; inactive entries are collectible
    without an eviction heuristic.  Every owner carries its own cooperative
    Eio gate and a shared Stdlib mutex, so unrelated Keeper lanes never
    serialize on queue I/O while Eio and non-Eio callers still exclude each
    other. *)

type resolve_error =
  | Invalid_base_path of string
  | Invalid_keeper_name of string

type t

val resolve_error_to_string : resolve_error -> string

val canonical_base_path : string -> (string, resolve_error) result
(** Resolve through the shared {!Config_dir_resolver.canonical_base_path}
    identity used by Keeper registry keys. The returned path is absolute and
    lexically canonical. *)

val resolve :
  base_path:string -> keeper_name:string -> (t, resolve_error) result
(** Resolve or create the unique in-process owner for this canonical
    [(base_path, keeper_name)] identity. *)

val base_path : t -> string
val keeper_name : t -> Keeper_id.Keeper_name.t

val with_lock : t -> (unit -> 'a) -> 'a
(** Serialize [f] with every Eio and non-Eio caller for this owner.

    Eio callers wait cooperatively: one fiber waits on the Eio gate and polls
    the shared Stdlib mutex with [Mutex.try_lock] plus [Fiber.yield].  Once both
    locks are held, cancellation is protected until [f] finishes and both
    locks are released; cancellation is checked again before a value or an
    ordinary exception can leave the lock boundary.
    Non-Eio callers use the same Stdlib mutex directly. *)

val with_durable_lock : t -> (unit -> 'a) -> 'a
(** Transaction lock for durable state changes.  Lock acquisition remains
    cancellable.  Once acquired, [f] and lock release are cancellation
    protected, and pending cancellation is deliberately not re-raised at this
    boundary.  This lets the caller receive a committed lease/receipt and
    settle it before cancellation propagates at the next cancellation point. *)
