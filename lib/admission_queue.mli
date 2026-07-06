(** Admission_queue — MASC-layer admission observability for inference calls.

    Current runtime mode is passthrough: provider-level throttling and retry
    ownership live in the OAS runtime layer. This module still records
    MASC-visible inflight state, host-resource rejection, and the configured
    capacity hint used by dashboards.

    The waiter metadata and priority helpers are retained as observability
    scaffolding for the RFC-0026 runtime-layer admission router. They are not
    an active MASC-side scheduler in the current call path.

    @since 3.0.0 *)

(** Metadata carried per waiter — for observability, not scheduling. *)
type waiter_info = {
  keeper_name : string;
  runtime_id : string;
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
  runtime_id:string ->
  (unit -> 'a) ->
  ('a, [> `Host_resource_saturated of string ]) result
(** Run [f] in passthrough mode and record inflight observation for metrics
    and snapshots. When an fd-pressure threshold is configured
    ([Otel_metric_process.fd_warn_threshold = Some _]) and the host FD count
    reaches it, returns [Error (`Host_resource_saturated msg)]; otherwise
    returns [Ok (f ())]. While the threshold is [None] (the default) the fd
    scan is skipped and every call is admitted.

    No MASC-side concurrency gate is applied here; OAS runtime owns provider
    capacity, retry, and timeout behavior. *)

val try_with_permit :
  priority:Llm_provider.Request_priority.t ->
  keeper_name:string ->
  runtime_id:string ->
  (unit -> 'a) ->
  'a option
(** Non-blocking variant. Returns [None] if host resources are saturated. *)

val try_with_permit_result :
  priority:Llm_provider.Request_priority.t ->
  keeper_name:string ->
  runtime_id:string ->
  (unit -> 'a) ->
  ('a, [> `Host_resource_saturated of string ]) result
(** Non-blocking variant with an explicit rejection result. Prefer this over
    [try_with_permit] for new callers. *)

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

  val check_host_resources_for_threshold :
    surface:Admission_queue_metrics.rejection_surface ->
    keeper_name:string ->
    threshold:int option ->
    fd_count:(unit -> int) ->
    (unit, [> `Host_resource_saturated of string ]) result
  (** The production gate as a pure function: [fd_count] is forced only when
      [threshold] is [Some _]. Tests pass a counting thunk to assert the
      [/dev/fd] scan is skipped while gating is disabled ([None]). *)

  val try_with_permit_result_for_threshold :
    keeper_name:string ->
    runtime_id:string ->
    threshold:int option ->
    fd_count:(unit -> int) ->
    (unit -> 'a) ->
    ('a, [> `Host_resource_saturated of string ]) result
  (** Test hook for [try_with_permit_result] with deterministic host-resource
      inputs. *)

  val apply_active_delta :
    active:int -> delta:int -> (int, [> `Counter_underflow of int ]) result
  (** Pure counter update. Returns the new active count, or an explicit
      underflow error instead of silently clamping. *)

  val bump_active :
    ?loc:string -> int -> (unit, [> `Counter_underflow of int ]) result
  (** Global counter update used in production. Returns the explicit underflow
      error and leaves the counter unchanged instead of silently clamping. *)

  val get_active : unit -> int
  (** Current active count from the global queue cell. *)
end
