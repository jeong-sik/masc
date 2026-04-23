(** Admission_queue — MASC-layer priority admission queue for inference calls.

    Sits between MASC callers and OAS Agent.run(). Provides:
    - Configurable concurrency limits per queue partition
    - Priority-aware FIFO scheduling (reuses OAS Request_priority ranking)
    - Per-waiter metadata for observability (keeper_name, enqueue_ts)
    - Cancel-safe via Eio.Promise + Atomic cancellation flag

    The implementation mirrors OAS Slot_scheduler semantics (priority sorted
    waiter list, Eio.Promise blocking) at the MASC layer with MASC-visible
    metadata.

    @since 3.0.0 *)

(** Metadata carried per waiter — for observability, not scheduling. *)
type waiter_info = {
  keeper_name : string;
  cascade_name : string;
  enqueue_ts : float;
  priority : Llm_provider.Request_priority.t;
}

(** Queue-level snapshot for observability. *)
type snapshot = {
  max_concurrent : int;
  active : int;
  available : int;
  queue_depth : int;
  waiters : waiter_info list;
}

val initial_max_concurrent_of_env : (string -> string option) -> int
(** Resolve the startup queue capacity from environment variables.

    Ownership is intentionally MASC-local: only [MASC_ADMISSION_MAX_CONCURRENT]
    affects the admission queue. Provider-specific knobs such as
    [OLLAMA_NUM_PARALLEL] must not implicitly resize the global MASC queue. *)

val with_permit :
  ?wait_timeout_sec:float ->
  priority:Llm_provider.Request_priority.t ->
  keeper_name:string ->
  cascade_name:string ->
  (unit -> 'a) ->
  ('a, [> `Host_resource_saturated of string ]) result
(** Acquire a permit, run [f], release permit on exit (normal or exception).
    Returns [Error (`Host_resource_saturated msg)] if host FD count exceeds
    the safety threshold. Otherwise returns [Ok (f ())].

    Emits Prometheus metrics via [Admission_queue_metrics] on
    enqueue/dequeue/acquire/release. *)

val try_with_permit :
  priority:Llm_provider.Request_priority.t ->
  keeper_name:string ->
  cascade_name:string ->
  (unit -> 'a) ->
  'a option
(** Non-blocking variant. Returns [None] if host resources are saturated. *)

val snapshot : unit -> snapshot
(** Current queue state for observability. Non-blocking. *)

val snapshot_json : unit -> Yojson.Safe.t
(** JSON representation of [snapshot] for dashboard/MCP consumption. *)

val set_max_concurrent : int -> unit
(** Runtime reconfiguration. If lowered while permits are active,
    no permits are revoked — new acquires block until active drops
    below the new limit.

    @raise Invalid_argument if [n < 1]. *)

val max_concurrent : unit -> int
(** Current configured max concurrent. *)

val reset_for_test : max_slots:int -> unit
(** Reset queue state for testing. Not for production use. *)
