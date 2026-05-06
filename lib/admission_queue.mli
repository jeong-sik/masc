(** Admission_queue — MASC-layer admission observability for inference calls.

    Current runtime mode is passthrough: provider-level throttling and retry
    ownership live in the OAS cascade layer. This module still records
    MASC-visible inflight state, host-resource rejection, and the configured
    capacity hint used by dashboards.

    The waiter metadata and priority helpers are retained as observability
    scaffolding for the RFC-0026 cascade-layer admission router. They are not
    an active MASC-side scheduler in the current call path.

    @since 3.0.0 *)

(** Metadata carried per waiter — for observability, not scheduling. *)
type waiter_info = {
  keeper_name : string;
  cascade_name : Keeper_cascade_profile.runtime_name;
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
  cascade_name:Keeper_cascade_profile.runtime_name ->
  (unit -> 'a) ->
  ('a, [> `Host_resource_saturated of string ]) result
(** Run [f] in passthrough mode and record inflight observation for metrics
    and snapshots. Returns [Error (`Host_resource_saturated msg)] if host FD
    count exceeds the safety threshold. Otherwise returns [Ok (f ())].

    No MASC-side concurrency gate is applied here; OAS cascade owns provider
    capacity, retry, and timeout behavior. *)

val try_with_permit :
  priority:Llm_provider.Request_priority.t ->
  keeper_name:string ->
  cascade_name:Keeper_cascade_profile.runtime_name ->
  (unit -> 'a) ->
  'a option
(** Non-blocking variant. Returns [None] if host resources are saturated. *)

val snapshot : unit -> snapshot
(** Current queue state for observability. Non-blocking. *)

val snapshot_json : unit -> Yojson.Safe.t
(** JSON representation of [snapshot] for dashboard/MCP consumption. *)

val set_max_concurrent : int -> unit
(** Runtime reconfiguration of the dashboard capacity hint. In passthrough
    mode this does not block new calls or revoke active calls.

    @raise Invalid_argument if [n < 1]. *)

val max_concurrent : unit -> int
(** Current configured max concurrent. *)

val reset_for_test : max_slots:int -> unit
(** Reset queue state for testing. Not for production use. *)

module For_testing : sig
  (** Test-only hooks. These are exposed for deterministic unit coverage and are
      not part of the production API contract. *)

  val check_host_resources :
    surface:Admission_queue_metrics.rejection_surface ->
    keeper_name:string ->
    fd_count:int ->
    threshold:int ->
    (unit, [> `Host_resource_saturated of string ]) result
  (** Deterministic host-resource check for threshold tests. *)
end
