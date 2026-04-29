(** Per-call OAS telemetry collector backing the [/oas/telemetry] dashboard.

    Layer 4 collector for {b I1 Telemetry pipeline} (#11924, Phase 1, Track T1)
    of the [Meta] MASC-MCP × OAS root improvement plan (#11923).

    Twelve signals are recorded per LLM call so the dashboard can derive
    TTFB distribution, throughput, cost, cache-hit ratio, and the bimodal
    hang signature (100–200s normal vs 2,000–3,000s zombie tail). The
    collector is intentionally additive — existing metric paths remain
    untouched until I7 (string elimination) and I2 (provider_error variant)
    converge into a Type Triad SSOT.

    In-process, mutex-protected ring buffer keyed by [provider_id]. The
    buffer caps itself at a small bounded window per provider so recording
    is O(1) amortized and memory stays bounded regardless of emit volume.

    OAS workers call {!record} after each LLM turn (tool path or chat path),
    and the REST/SSE endpoints read from {!recent} and {!summary}.

    Cross-domain: guarded by [Stdlib.Mutex]. Eio fibers may call these
    functions directly; the critical section is short (queue push or fold)
    and never yields to Eio. Same lock-discipline rationale as the
    {!Dashboard_attribution} collector.

    @since unreleased *)

(** Outcome status of a single OAS call. Mirrors the variant intent of
    {!Provider_error} (I2 #11925) but kept local to the bridge so this
    module does not yet depend on the WIP Type Triad. *)
type status =
  | Success
  | Error of { transient : bool }
  | Cancelled of { reason : string }
  | Timeout

(** Twelve-signal telemetry sample for a single OAS LLM call.

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
  input_tokens : int;  (** Prompt tokens consumed. *)
  output_tokens : int;  (** Completion tokens produced. *)
  throughput_tokens_per_s : float;
      (** [output_tokens / max(total_duration_ms - ttfb_ms, 1.0) * 1000.0]. *)
  cost_usd : float;
      (** Dollar cost; [0.0] when unknown — CLI providers (codex_cli,
          gemini_cli, kimi_cli) intentionally strip usage metadata. *)
  cache_hit : bool;
      (** Prefix or implicit cache hit detected by the provider. *)
  status : status;  (** Outcome of the call. *)
  retry_count : int;
      (** Number of cascade retries attempted before this sample (0 for the
          first attempt). *)
}

val record : sample -> unit
(** [record s] appends [s] to its provider's ring. Thread-safe.
    When the per-provider cap is reached, the oldest entry is dropped. *)

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
}

val summary : ?provider:string -> ?limit:int -> unit -> summary
(** [summary ?provider ?limit ()] aggregates over the same window as
    {!recent}.

    {b Cycle 2 stub}: returns [zero_summary] until percentile and reduce
    logic land in the next cycle (#11924 follow-up). The signature is
    pinned now so call sites can be wired in I1's later cycles without
    breaking changes. *)

val clear : ?provider:string -> unit -> unit
(** [clear ?provider ()] drops samples. With [provider] only that ring is
    cleared. Without [provider] the entire table is reset.

    Intended for test fixtures and dashboard reset; do not call from
    production code. *)
