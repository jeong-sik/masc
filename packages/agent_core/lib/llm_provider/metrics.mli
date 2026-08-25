(** Metrics hooks for LLM completion observability.

    Consumers inject their own metrics backend (Prometheus, StatsD, log, etc.)
    via the [t] record. AGENT_CORE never depends on a specific implementation.

    @since 0.54.0

    @stability Internal
    @since 0.93.1 *)

(** Circuit-breaker state encoded for metrics backends. The integer
    mapping follows the common gauge convention:
    [0=closed], [1=open], [2=half-open]. *)
type circuit_state =
  | Circuit_closed
  | Circuit_open
  | Circuit_half_open

val circuit_state_to_int : circuit_state -> int
val circuit_state_to_string : circuit_state -> string

(** Bounded failure classification supplied by the typed transport boundary.
    Metric consumers must not infer this value from the diagnostic message. *)
type error_reason =
  | Rate_limit
  | Timeout
  | Unknown

val error_reason_to_string : error_reason -> string

(** Metrics callback interface. All callbacks are optional — provide [noop]
    as a default that does nothing.

    [on_http_status] fires once per HTTP response from a provider,
    regardless of whether the call ultimately succeeds or fails, so
    operators can plot request volume broken down by
    [{provider, model, status}]. Network/timeout errors that never
    produced a status do NOT fire this callback — those still surface
    through [on_error] as before. *)
type t =
  { on_cache_hit : model_id:string -> unit
  ; on_cache_miss : model_id:string -> unit
  ; on_request_start : model_id:string -> unit
  ; on_request_end : model_id:string -> latency_ms:int option -> unit
  ; on_error : model_id:string -> message:string -> reason:error_reason -> unit
    (** Fired for a failed request. [message] is diagnostic text only; control
        flow and metric labels must use [reason]. *)
  ; on_http_status : provider:string -> model_id:string -> status:int -> unit
  ; on_circuit_state :
      provider:string
      -> model_id:string
      -> provider_key:string
      -> state:circuit_state
      -> unit
    (** Fired when provider circuit-breaker state is observed or updated.
        Backends can export this as a gauge using
        {!circuit_state_to_int}; [provider_key] keeps same-model,
        different-endpoint circuits distinguishable.

        @since 0.193.10 *)
  ; on_capability_drop : model_id:string -> field:string -> unit
  ; on_retry : provider:string -> model_id:string -> attempt:int -> unit
    (** Fired when a request is retried due to a retryable error.
      @since 0.185.0 *)
  ; on_token_usage :
      provider:string -> model_id:string -> input_tokens:int -> output_tokens:int -> unit
    (** Fired when a response carries usage tokens.
      @since 0.185.0 *)
  ; on_tool_calls : provider:string -> model_id:string -> count:int -> unit
    (** Fired when a provider response contains one or more AGENT_CORE [ToolUse]
        blocks. The count is provider-agnostic and represents calls emitted
        by the model, not tool execution success.
        @since 0.193.16 *)
  ; on_streaming_first_chunk :
      provider:string -> model_id:string -> ttfrc_ms:float -> unit
    (** Fired when a streaming response emits its first parsed response
        event and monotonic latency is available. [ttfrc_ms] is monotonic
        elapsed time-to-first-response-chunk.
        @since 0.193.12 *)
  ; on_streaming_chunk :
      provider:string
      -> model_id:string
      -> chunk_index:int
      -> inter_chunk_ms:float
      -> unit
    (** Fired for each subsequent parsed streaming response event.
        [inter_chunk_ms] is monotonic elapsed time since the previous
        measured parsed event. [chunk_index] is the zero-based index reported by
        the streaming telemetry event.  @since 0.193.12 *)
  }

(** No-op metrics — all callbacks do nothing. *)
val noop : t

(** Install a process-wide metrics sink.  When a caller invokes
    {!Complete.complete} (or a wrapper) without passing [~metrics]
    explicitly, the value installed here is used instead of {!noop}.

    Initialization ordering: {!Complete.complete} resolves
    [get_global ()] at call time, so each call re-reads whatever sink
    is currently installed — subsequent calls after [set_global] see
    the new value.  The only window where callers observe [noop] is
    for HTTP calls issued *before* the host has run its startup
    [set_global]; install the sink as early in bootstrap as possible
    (before any automated agent traffic) to avoid that gap.

    Intended to be called once at startup from the host application
    (e.g. a downstream consumer installs a Prometheus-backed instance).
    Thread-safe:
    a concurrent [set_global] is published atomically via [Atomic.set];
    fibers already holding the previous reference continue to use it
    until their current call returns. *)
val set_global : t -> unit

(** Read the current process-wide metrics sink.  Returns {!noop}
    unless {!set_global} has been called. *)
val get_global : unit -> t

(* ── Per-provider aggregating backend ───────────── *)

(** Immutable snapshot of accumulated counters for a single provider/model
    pair. Suitable for OTLP/Prometheus export or structured logging.
    [latency_ms_sum] and [latency_ms_count] include measured latency samples
    only; completions with unknown latency still increment [request_total].

    @since 0.188.0 *)
type provider_snapshot =
  { provider : string
  ; model_id : string
  ; request_total : int
  ; error_total : int
  ; retry_total : int
  ; input_tokens_total : int
  ; output_tokens_total : int
  ; tool_call_total : int
  ; latency_ms_sum : int
  ; latency_ms_count : int
  ; ttfrc_ms_sum : float
  ; ttfrc_ms_count : int
  ; inter_chunk_ms_sum : float
  ; inter_chunk_ms_count : int
  }

(** Convert one provider snapshot to structured JSON.

    @since 0.193.11 *)
val provider_snapshot_to_yojson : provider_snapshot -> Yojson.Safe.t

(** Convert provider snapshots to a stable JSON payload suitable for
    durable periodic flushes. The payload includes a [schema_version] field
    so downstream readers can evolve without guessing the shape.

    @since 0.193.11 *)
val provider_snapshots_to_yojson : provider_snapshot list -> Yojson.Safe.t

(** Mutable counters for a single aggregation key. *)
type aggregate_state

(** Alias for the hooks record {!t}, exposed so the {!Aggregating}
    submodule can reference it without name collision with its own [t]. *)
type hooks = t

(** Thread-safe aggregating metrics backend.

    Accumulates per-provider counters in a hash table guarded by a Stdlib
    mutex. The guarded sections are pure counter updates, so this stays safe
    for Eio callback paths while preserving the public snapshot/export API for
    non-Eio exporters and tests. Wrap an existing [Metrics.t] via
    {!Aggregating.create} to layer counting on top of any other metrics sink.
    Call {!Aggregating.snapshot} to read all counters as an immutable list.

    @since 0.188.0 *)
module Aggregating : sig
  type t

  (** Build the aggregation key from provider and model_id. *)
  val key : provider:string -> model_id:string -> string

  (** Create a new aggregator. [~inner] is the underlying metrics sink
      that receives callbacks before the aggregator increments its own
      counters. Defaults to {!noop}. *)
  val create : ?inner:hooks -> unit -> t

  (** Derive a hooks record that increments the aggregator's
      counters on each callback, then delegates to the inner sink. *)
  val to_hooks : t -> hooks

  (** Read all accumulated counters as an immutable snapshot list. *)
  val snapshot : t -> provider_snapshot list

  (** Read all accumulated counters and encode them as stable JSON. *)
  val snapshot_to_yojson : t -> Yojson.Safe.t

  (** Atomically persist the current snapshot as pretty JSON. Creates parent
      directories before writing with a writer-unique temporary file and
      rename. *)
  val save_snapshot_json : t -> path:string -> (unit, string) result

  (** Reset all counters to zero. *)
  val reset : t -> unit
end
