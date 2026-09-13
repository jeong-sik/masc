(** In-process notifications of authoritative current-memory snapshot commits.

    This is a wake signal, not a durable event journal or a semantic approval.
    Consumers must read the current stores when processing a wake; revisions can
    arrive out of order after concurrent writers release their store locks. *)

type store = Ordinary | Source_bound

type event =
  { keepers_dir : string
      (** Canonical physical directory, resolved before the committing writer
          acquires store locks. Consumers need no filesystem lookup in a wake. *)
  ; keeper_id : string
  ; store : store
  ; revision : int
  }

val subscribe : (event -> unit) -> (unit -> unit)
(** Register a callback and return an idempotent unsubscribe function. Callbacks
    run synchronously on the committing caller's domain, outside the memory
    stores' locks and this module's registry lock. They must only enqueue a wake:
    no filesystem reads, model work, blocking or yielding operations.

    An unsubscribe racing an already-started dispatch may leave one in-flight
    callback. A lifecycle owner must also disregard wakes after shutdown. *)

val notify_committed : event -> unit
(** Called by snapshot persistence owners only, after a successful authoritative
    write and after releasing all store locks. Failed writes and unchanged
    revalidations must not notify. Callback failures are isolated and logged;
    they cannot undo the committed snapshot or prevent other subscriptions from
    observing it. Cancellation is propagated with its backtrace after notifying
    the remaining subscriptions. This does not read or depend on a journal. *)
