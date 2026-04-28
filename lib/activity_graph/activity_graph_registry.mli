(** Activity_graph_registry — SSE client registry guarded by an
    [Eio.Mutex].

    {!Activity_graph} re-exports the public surface via
    [include Activity_graph_registry] so it can iterate
    {!clients} and {!client_matches} from inside its event
    fan-out without re-introducing the cycle this split was
    extracted to break.

    Internal storage (the [registry_mutex] handle, the
    [client_count_atomic] counter, and the [client_id_counter]
    monotonic id source) is hidden — callers consume only the
    locked accessors and the lifecycle entry points. *)

open Activity_graph_types

type client = {
  client_id : int;
  push : string -> unit;
  kind_filters : string list;
  mutable last_seq : int;
  created_at : float;
}
(** A registered SSE client. The record is exposed concretely
    because {!Activity_graph} reads / mutates [last_seq] from
    inside the fan-out and reads [kind_filters] via
    {!client_matches}; hiding the layout would force getter
    pairs without making the abstraction any richer. *)

val clients : (string, client) Hashtbl.t
(** Live session-id → client table. {!Activity_graph} iterates
    this Hashtbl from its broadcast loop under
    {!with_registry_ro}; mutations must go through {!register} /
    {!unregister} / {!unregister_if_current}. *)

val with_registry_rw :
  (unit -> 'a) -> 'a
(** Run [f ()] under a read-write lock on {!clients}. When the
    Eio runtime is not yet ready ([Eio_guard.is_ready () = false],
    e.g. during boot), [f ()] runs unlocked — the registry has
    no readers / writers at that point.
    [Eio.Cancel.Cancelled] propagates unchanged. *)

val with_registry_ro :
  (unit -> 'a) -> 'a
(** Read-only variant of {!with_registry_rw}. Same boot-time
    fast path. *)

val client_matches : client -> event -> bool
(** [true] when [client.kind_filters] is empty (subscribe-all)
    or when [event.kind] is in the filter list. *)

val register :
  string ->
  push:(string -> unit) ->
  last_seq:int ->
  ?kind_filters:string list ->
  unit ->
  int
(** Register or replace the client for [session_id] and return
    the freshly-allocated [client_id] (monotonic, never reused).
    A re-register with the same [session_id] preserves the
    counter — only new sessions increment {!client_count}. *)

val unregister : string -> unit
(** Drop the client for [session_id] unconditionally. No-op when
    no client is registered. *)

val unregister_if_current : string -> int -> unit
(** Drop the client for [session_id] iff its current
    [client_id] equals the given one. Used to avoid a TOCTOU
    where a slow disconnect handler removes a client another
    fiber has already replaced via {!register}. *)

val client_count : unit -> int
(** Number of distinct [session_id]s currently registered.
    Backed by an [Atomic.t] so the read does not take the
    registry lock. *)
