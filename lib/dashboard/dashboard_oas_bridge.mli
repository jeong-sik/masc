(** Per-call OAS telemetry collector backing the [/oas/telemetry] dashboard.

    Layer 4 collector for {b I1 Telemetry pipeline} (#11924, Phase 1, Track T1)
    of the [Meta] MASC-MCP × OAS root improvement plan (#11923).

    Per-call signals are recorded so the dashboard can derive TTFB
    distribution, throughput, cost, cache-hit ratio, and the bimodal
    hang signature (100–200s normal vs 2,000–3,000s zombie tail). The
    collector is intentionally additive — existing metric paths remain
    untouched until I7 (string elimination) and I2 (provider_error variant)
    converge into a Type Triad SSOT.

    In-process, mutex-protected ring buffer keyed by [provider_id]. The
    buffer caps itself at a small bounded window per provider so recording
    is O(1) amortized and memory stays bounded regardless of emit volume.

    OAS workers call {!record} after each LLM turn (tool path or chat path),
    and the REST/SSE endpoints read from {!recent} and {!summary}. Each
    recorded sample is also emitted to Observer SSE sessions as an additive
    [oas_telemetry_sample] dashboard event.

    Cross-domain: guarded by [Stdlib.Mutex]. Eio fibers may call these
    functions directly; the critical section is short (queue push or fold)
    and never yields to Eio. Same lock-discipline rationale as the
    {!Dashboard_attribution} collector.

    @since unreleased *)

(** Outcome status of a single OAS call. Mirrors the variant intent of
    {!Provider_error} (I2 #11925) but stays local because telemetry
    samples and provider-error event counts have different lifecycles. *)
type status =
  | Success
  | Error of { transient : bool }
  | Cancelled of { reason : string }
  | Timeout

(** Telemetry sample for a single OAS LLM call.

    Naming follows OpenTelemetry GenAI semantic convention [gen_ai.*]. The
    bridge does not commit to that namespace at the OCaml type level — the
    naming alignment happens at the dashboard JSON serialization layer in
    a later cycle. *)
type sample = {
  provider_id : string;
      (** e.g. ["anthropic"], ["ollama"], ["codex_cli"]. *)
  model_id : string;  (** e.g. ["claude-opus-4-7"]. *)
  ttfb_ms : float;
      (** Time-to-first-byte (or first token) in milliseconds. *)
  total_duration_ms : float;  (** Full call duration in milliseconds. *)
  serialization_ms : float;
      (** Request serialize + response parse overhead in milliseconds.
          Captures the adapter cost the docx flagged as currently invisible. *)
  usage_reported : bool;
      (** [true] when OAS supplied provider usage. Missing usage remains
          distinct from real zero-token usage. *)
  input_tokens : int option;  (** Prompt tokens consumed, when reported. *)
  output_tokens : int option;
      (** Completion tokens produced, when reported. *)
  throughput_tokens_per_s : float option;
      (** [output_tokens / max(total_duration_ms - ttfb_ms, 1.0) * 1000.0]. *)
  cost_usd : float option;
      (** Dollar cost, when reported — CLI providers (codex_cli, gemini_cli,
          kimi_cli) intentionally strip usage metadata. *)
  cache_hit : bool option;
      (** Prefix or implicit cache hit detected by the provider. *)
  status : status;  (** Outcome of the call. *)
  retry_count : int;
      (** Number of cascade retries attempted before this sample (0 for the
          first attempt). *)
}

val record : sample -> unit
(** [record s] appends [s] to its provider's ring. Thread-safe.
    When the per-provider cap is reached, the oldest entry is dropped. *)

val sample_of_response :
  provider_id:string ->
  model_id:string ->
  ?total_duration_ms:float ->
  ?serialization_ms:float ->
  ?retry_count:int ->
  status:status ->
  Agent_sdk.Types.api_response ->
  sample
(** [sample_of_response ~provider_id ~model_id ?total_duration_ms
    ?serialization_ms response] projects an OAS [api_response] into the
    twelve-signal bridge sample.

    - [usage] fields become token, cost, and cache-hit signals.
    - [response.telemetry.request_latency_ms] is used as duration when the
      caller does not provide [total_duration_ms].
    - native decode throughput is preferred when OAS telemetry exposes it;
      otherwise wall-clock throughput is derived from output tokens and
      duration.
    - [serialization_ms] carries request-serialize + response-parse overhead
      measured at the adapter boundary; defaults to [0.0] when not provided.

    Missing OAS usage is represented with [usage_reported = false] and
    nullable usage-derived fields rather than synthetic zeroes. Missing
    telemetry remains nullable where the signal cannot be derived. *)

val record_response :
  provider_id:string ->
  model_id:string ->
  ?total_duration_ms:float ->
  ?serialization_ms:float ->
  ?retry_count:int ->
  status:status ->
  Agent_sdk.Types.api_response ->
  unit
(** Convert an OAS response with {!sample_of_response}, then {!record} it. *)

type provider_error_count = {
  provider_id : string;
  cascade_name : string;
  kind : string;
  capacity_scope : string;
  count : int;
}
(** Aggregated provider-error variant count emitted by the OAS worker
    boundary. [kind] follows {!Provider_error.to_error_kind};
    [capacity_scope] is ["none"] for non-capacity errors. *)

val record_provider_error :
  cascade_name:string -> provider_id:string -> Provider_error.t -> unit
(** [record_provider_error ~cascade_name ~provider_id error] increments the
    dashboard count for a typed provider-error event. *)

val provider_error_counts : ?provider:string -> unit -> provider_error_count list
(** Current provider-error counts, sorted by descending [count]. With
    [provider], only matching provider rows are returned. *)

val recent :
  ?provider:string -> ?limit:int -> unit -> (sample * float) list
(** [recent ?provider ?limit ()] returns up to [limit] most recent samples,
    newest first. Each tuple is [(sample, recorded_at)] where
    [recorded_at] is [Unix.gettimeofday] at {!record} time.

    - Default [limit] is [50].
    - When [provider] is provided, only that provider's ring is scanned.
      Unknown providers return [[]].
    - When [provider] is absent, samples are merged across providers and
      sorted by [recorded_at] descending. *)

(** Aggregate over a sliding window of samples.

    All percentile fields use the nearest-rank method
    (TLA+-friendly, no interpolation), which keeps the dashboard
    deterministic even with very small windows. *)
type summary = {
  sample_count : int;
  ttfb_p50_ms : float;
  ttfb_p95_ms : float;
  total_duration_p50_ms : float;
  total_duration_p95_ms : float;
  total_duration_p99_ms : float;
      (** Zombie-tail detector — bimodal hang shows up here. *)
  cache_hit_ratio : float;  (** In [\[0.0, 1.0\]]. *)
  total_cost_usd : float;  (** Sum across the window. *)
  error_ratio : float;
      (** [(Error \/ Timeout) / sample_count] — Cancelled is excluded. *)
  cancelled_count : int;  (** Explicit cancellation count. *)
  provider_error_counts : provider_error_count list;
}

val summary : ?provider:string -> ?limit:int -> unit -> summary
(** [summary ?provider ?limit ()] aggregates over the same window as
    {!recent}.

    Returns a zero-valued summary (all fields [0]) when no samples match
    the filter. Otherwise the percentile fields use the nearest-rank
    method (no interpolation): for [n] sorted samples and probability
    [p], the percentile is the value at index [ceil(p*n) - 1], clamped
    to [\[0, n-1\]]. The choice keeps the dashboard deterministic with
    very small windows (e.g. one sample → p50 = p95 = the only value). *)

val status_to_yojson : status -> Yojson.Safe.t
(** JSON projection used by the dashboard REST/SSE surface. *)

val sample_to_yojson : sample -> Yojson.Safe.t
(** JSON projection of the twelve-signal sample fields. *)

val sample_entry_to_yojson : sample * float -> Yojson.Safe.t
(** JSON projection of [(sample, recorded_at)]. *)

val summary_to_yojson : summary -> Yojson.Safe.t
(** JSON projection of aggregate fields from {!summary}. *)

val recent_json : ?provider:string -> ?limit:int -> unit -> Yojson.Safe.t
(** Dashboard payload for
    [GET /api/v1/dashboard/oas/telemetry/recent?provider=P&limit=N]. *)

val summary_json : ?provider:string -> ?limit:int -> unit -> Yojson.Safe.t
(** Dashboard payload for
    [GET /api/v1/dashboard/oas/telemetry/summary?provider=P&limit=N]. *)

val clear : ?provider:string -> unit -> unit
(** [clear ?provider ()] drops samples and provider-error counts. With
    [provider] only that provider's ring/counts are cleared. Without
    [provider] the entire telemetry table is reset.

    Intended for test fixtures and dashboard reset; do not call from
    production code. *)
