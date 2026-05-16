(** Bridge between OAS Llm_provider.Metrics.t and the masc-mcp
    Prometheus counter registry.

    OAS exposes a set of callback hooks on every LLM HTTP call
    (on_request_start, on_request_end, on_error, on_http_status, …).
    The host application installs a single process-wide sink via
    [Llm_provider.Metrics.set_global], and OAS's Complete.complete
    resolves it at call time for every code path that does not
    explicitly thread [~metrics].

    This module constructs the sink.  Most callbacks relay directly into
    [Prometheus.inc_counter] on a named metric.  The exception is request
    latency: OAS [on_request_end] carries [model_id] but not [provider], so
    the bridge keeps a tiny model→provider cache from adjacent callbacks
    ([on_http_status], [on_retry], [on_token_usage]) to label latency
    histograms without changing the OAS API.

    @since 0.4.x (telemetry chain: oas#804 + oas#807) *)

(** Canonical metric name for provider HTTP response counts.

    Label cardinality (practical upper bound as of v0.4.x):
    - [provider]: fixed enum of 6 canonical values (ollama, glm,
      glm-coding, anthropic, openai, gemini, claude_code)
    - [model]: bounded by entries in [config/cascade.toml], typically
      under 10 distinct values per deployment
    - [status]: small set of HTTP codes the provider actually emits
      (usually 200, 400, 401, 429, 500, 503)

    Upper bound ≈ 6 × 10 × 10 = 600 series.  No runtime cardinality
    guard; if a deployment introduces unbounded custom model ids,
    revisit with an allowlist or drop the [model] label. *)
let http_status_metric = Prometheus.metric_llm_provider_http_status

(** Canonical metric name for silent capability drops. *)
let capability_drop_metric = Prometheus.metric_llm_provider_capability_drops
let cache_hit_metric = Prometheus.metric_llm_provider_cache_hits
let cache_miss_metric = Prometheus.metric_llm_provider_cache_misses
let request_start_metric = Prometheus.metric_llm_provider_requests_started
let error_metric = Prometheus.metric_llm_provider_errors
let error_by_reason_metric = Prometheus.metric_llm_provider_errors_by_reason
let retry_metric = Prometheus.metric_llm_provider_retries
let input_tokens_metric = Prometheus.metric_llm_provider_input_tokens
let output_tokens_metric = Prometheus.metric_llm_provider_output_tokens
let tool_calls_metric = Prometheus.metric_llm_provider_tool_calls
let circuit_state_metric = Prometheus.metric_llm_provider_circuit_state
let streaming_first_chunk_metric =
  Prometheus.metric_llm_provider_streaming_first_chunk

let streaming_inter_chunk_metric =
  Prometheus.metric_llm_provider_streaming_inter_chunk

let unknown_provider_label = "unknown"
let provider_cache_max_entries = 256
let provider_by_model : (string, string) Hashtbl.t = Hashtbl.create 32
let provider_cache_mutex = Stdlib.Mutex.create ()

let nonempty_or_none value =
  let value = String.trim value in
  if value = "" then None else Some value

let remember_provider ~model_id ~provider =
  match nonempty_or_none model_id, nonempty_or_none provider with
  | Some model_id, Some provider ->
    Stdlib.Mutex.protect provider_cache_mutex (fun () ->
      if Hashtbl.length provider_by_model >= provider_cache_max_entries
         && not (Hashtbl.mem provider_by_model model_id)
      then Hashtbl.clear provider_by_model;
      Hashtbl.replace provider_by_model model_id provider)
  | _ -> ()

(** Resolution outcome for the [provider] label of a latency observation.
    Internal — kept out of [.mli] so callers stay byte-identical.

    Replaces the previous [Option.value ~default:unknown_provider_label]
    fallback in [provider_for_latency], which silently collapsed two
    distinct conditions (empty [model_id] vs. cache miss) into the same
    label. The variant lets [emit_request_latency] increment the
    pre-existing [request_latency_clamped] counter with a typed [reason]
    so cache misses are visible per provider. *)
type provider_resolution =
  | Provider_explicit of string
      (** Caller supplied non-empty [?provider]. *)
  | Provider_cached of string
      (** Caller omitted [?provider]; recovered via model→provider cache. *)
  | Provider_unknown_no_model_id
      (** Caller omitted [?provider] and [model_id] is empty after trim. *)
  | Provider_unknown_cache_miss of { model_id : string }
      (** Caller omitted [?provider]; [model_id] non-empty but absent from
          cache (no adjacent [on_http_status] / [on_retry] /
          [on_token_usage] observed yet). *)

let resolve_provider_for_latency ?provider ~model_id () =
  match Option.bind provider nonempty_or_none with
  | Some provider ->
    remember_provider ~model_id ~provider;
    Provider_explicit provider
  | None ->
    let model_id = String.trim model_id in
    if model_id = "" then Provider_unknown_no_model_id
    else
      Stdlib.Mutex.protect provider_cache_mutex (fun () ->
        match Hashtbl.find_opt provider_by_model model_id with
        | Some cached -> Provider_cached cached
        | None -> Provider_unknown_cache_miss { model_id })

(** Project a [provider_resolution] to the Prometheus [provider] label.
    Cardinality budget unchanged: both unknown variants emit
    [unknown_provider_label] so the upper bound stays at the documented
    6 × 10 × 10 = 600 series. *)
let provider_label_of_resolution = function
  | Provider_explicit p | Provider_cached p -> p
  | Provider_unknown_no_model_id | Provider_unknown_cache_miss _ ->
    unknown_provider_label

(** Emit a single HTTP status observation to the Prometheus counter.

    Exposed so that per-call metrics sinks (e.g. the cascade-observation
    capture in [Cascade_legacy_runner]) can forward [on_http_status] to the
    same counter without duplicating the label shape.  This is the
    single source of truth for the label key names. *)
let emit_http_status ~provider ~model_id ~status =
  remember_provider ~model_id ~provider;
  Prometheus.inc_counter http_status_metric
    ~labels:
      [
        ("provider", provider);
        ("model", model_id);
        ("status", string_of_int status);
      ]
    ()

(** Emit a capability drop observation to the Prometheus counter. *)
let emit_capability_drop ~model_id ~field =
  Prometheus.inc_counter capability_drop_metric
    ~labels:[("model", model_id); ("field", field)]
    ()

let emit_cache_hit ~model_id =
  Prometheus.inc_counter cache_hit_metric
    ~labels:[("model", model_id)]
    ()

let emit_cache_miss ~model_id =
  Prometheus.inc_counter cache_miss_metric
    ~labels:[("model", model_id)]
    ()

let emit_request_start ~model_id =
  Prometheus.inc_counter request_start_metric
    ~labels:[("model", model_id)]
    ()

(** Closed sum classifying the free-form OAS error string from
    [on_error] into the Prometheus [error_reason] label values.

    Internal — kept out of [.mli] so callers stay byte-identical.

    Replaces the previous two [else "unknown"] catch-alls (one for the
    empty trimmed input, one for the substring sieve falling through)
    with two distinct variants. [Reason_absent] is the documented "no
    diagnostic available" path; [Reason_unmapped] preserves the trimmed
    lower-case substring so a future audit counter labeled by unmapped
    head-of-string can show which provider error shapes the sieve does
    not yet recognise. Both project to the same [unknown] label today
    so the bounded-cardinality assumption (~10 reasons) is preserved.

    The substring sieve itself is *not* expanded by this PR — adding
    more string classifiers is the CLAUDE.md §워크어라운드 시그니처 #2
    antipattern. The typed variant is the surface that makes future
    closure possible (typed provider error → [error_reason] mapping
    in OAS, removing this sieve). *)
type error_reason =
  | Reason_timeout
  | Reason_cancelled
  | Reason_rate_limit
  | Reason_quota
  | Reason_capacity
  | Reason_auth
  | Reason_network
  | Reason_parse
  | Reason_invalid_request
  | Reason_provider_error
  | Reason_unmapped of { trimmed_lower : string }
  | Reason_absent

let classify_error_reason error =
  let lower = String.lowercase_ascii (String.trim error) in
  let has needle = String_util.contains_substring lower needle in
  if lower = "" then Reason_absent
  else if has "timeout" || has "timed out" || has "deadline" then Reason_timeout
  else if has "cancel" then Reason_cancelled
  else if has "429" || has "rate limit" || has "too many requests" then
    Reason_rate_limit
  else if has "quota" then Reason_quota
  else if has "capacity" || has "overloaded" then Reason_capacity
  else if has "401" || has "403" || has "unauthorized" || has "forbidden"
          || has "auth" then Reason_auth
  else if has "connection" || has "network" || has "dns" || has "socket"
          || has "econn" then Reason_network
  else if has "json" || has "parse" || has "unparseable" then Reason_parse
  else if has "400" || has "invalid" || has "schema" || has "validation" then
    Reason_invalid_request
  else if has "500" || has "503" || has "provider" || has "internal server"
  then Reason_provider_error
  else Reason_unmapped { trimmed_lower = lower }

(** Project an [error_reason] to the Prometheus label. Both
    [Reason_absent] and [Reason_unmapped] project to ["unknown"] —
    cardinality budget unchanged. *)
let error_reason_label = function
  | Reason_timeout -> "timeout"
  | Reason_cancelled -> "cancelled"
  | Reason_rate_limit -> "rate_limit"
  | Reason_quota -> "quota"
  | Reason_capacity -> "capacity"
  | Reason_auth -> "auth"
  | Reason_network -> "network"
  | Reason_parse -> "parse"
  | Reason_invalid_request -> "invalid_request"
  | Reason_provider_error -> "provider_error"
  | Reason_unmapped _ | Reason_absent -> "unknown"

let emit_error ~model_id ~error =
  Prometheus.inc_counter error_metric
    ~labels:[("model", model_id)]
    ();
  let reason = classify_error_reason error in
  Prometheus.inc_counter error_by_reason_metric
    ~labels:
      [ ("model", model_id); ("error_reason", error_reason_label reason) ]
    ()

let emit_retry ~provider ~model_id ~attempt =
  remember_provider ~model_id ~provider;
  Prometheus.inc_counter retry_metric
    ~labels:
      [
        ("provider", provider);
        ("model", model_id);
        ("attempt", string_of_int attempt);
      ]
    ()

let emit_token_usage ~provider ~model_id ~input_tokens ~output_tokens =
  remember_provider ~model_id ~provider;
  if input_tokens > 0 then
    Prometheus.inc_counter input_tokens_metric
      ~labels:[("provider", provider); ("model", model_id)]
      ~delta:(Float.of_int input_tokens)
      ();
  if output_tokens > 0 then
    Prometheus.inc_counter output_tokens_metric
      ~labels:[("provider", provider); ("model", model_id)]
      ~delta:(Float.of_int output_tokens)
      ()

let emit_tool_calls ~provider ~model_id ~count =
  remember_provider ~model_id ~provider;
  if count > 0 then
    Prometheus.inc_counter tool_calls_metric
      ~labels:[("provider", provider); ("model", model_id)]
      ~delta:(Float.of_int count)
      ()

(** Validation outcome for a streaming or latency duration carried in
    milliseconds. Internal — kept out of [.mli] so callers stay
    byte-identical.

    Replaces the previous [seconds_of_ms : float -> float option] +
    [| None -> ()] silent drop at both streaming call sites. The two
    invalid cases (NaN/Inf vs. non-positive) are distinct production
    bugs in the OAS provider plumbing — collapsing them to [None]
    blanked out the operator signal. The reason variant routes to the
    new [streaming_invalid_ms] counter with a typed [reason] label so
    each invalid sample is visible. *)
type ms_duration =
  | Ms_valid of float                    (** seconds, positive, finite. *)
  | Ms_invalid_not_finite                (** NaN or ±∞ in the input. *)
  | Ms_invalid_non_positive              (** zero or negative input. *)

let classify_ms ms : ms_duration =
  if not (Float.is_finite ms) then Ms_invalid_not_finite
  else if ms <= 0.0 then Ms_invalid_non_positive
  else Ms_valid (Float.max 0.001 (ms /. 1000.0))

let ms_invalid_reason = function
  | Ms_invalid_not_finite -> "not_finite"
  | Ms_invalid_non_positive -> "non_positive"
  | Ms_valid _ ->
    (* Unreachable — caller only invokes on invalid branches. The
       exhaustive match is preserved here so adding a new invalid
       variant in [ms_duration] forces a compile error here too. *)
    assert false

let streaming_first_chunk_invalid_metric =
  Prometheus.metric_llm_provider_streaming_first_chunk_invalid

let streaming_inter_chunk_invalid_metric =
  Prometheus.metric_llm_provider_streaming_inter_chunk_invalid

let emit_streaming_first_chunk ~provider ~model_id ~ttfrc_ms =
  remember_provider ~model_id ~provider;
  match classify_ms ttfrc_ms with
  | Ms_valid seconds ->
    Otel_spans.add_event
      ~name:"ttfrc.received"
      ~attrs:
        [ "gen_ai.provider.name", `String provider
        ; "gen_ai.request.model", `String model_id
        ; "masc.gen_ai.streaming.ttfrc_ms", `Float ttfrc_ms
        ]
      ();
    Prometheus.observe_histogram streaming_first_chunk_metric
      ~labels:[("provider", provider); ("model", model_id)]
      seconds
  | (Ms_invalid_not_finite | Ms_invalid_non_positive) as invalid ->
    Prometheus.inc_counter streaming_first_chunk_invalid_metric
      ~labels:
        [ ("provider", provider)
        ; ("model", model_id)
        ; ("reason", ms_invalid_reason invalid)
        ]
      ()

let emit_streaming_chunk ~provider ~model_id ~chunk_index ~inter_chunk_ms =
  remember_provider ~model_id ~provider;
  match classify_ms inter_chunk_ms with
  | Ms_valid seconds ->
    Otel_spans.add_event
      ~name:"streaming.chunk"
      ~attrs:
        [ "gen_ai.provider.name", `String provider
        ; "gen_ai.request.model", `String model_id
        ; "masc.gen_ai.streaming.chunk_index", `Int chunk_index
        ; "masc.gen_ai.streaming.inter_chunk_ms", `Float inter_chunk_ms
        ]
      ();
    Prometheus.observe_histogram streaming_inter_chunk_metric
      ~labels:[("provider", provider); ("model", model_id)]
      seconds
  | (Ms_invalid_not_finite | Ms_invalid_non_positive) as invalid ->
    Prometheus.inc_counter streaming_inter_chunk_invalid_metric
      ~labels:
        [ ("provider", provider)
        ; ("model", model_id)
        ; ("reason", ms_invalid_reason invalid)
        ]
      ()

let emit_circuit_state ~provider ~model_id ~provider_key ~state =
  remember_provider ~model_id ~provider;
  let value =
    Float.of_int (Llm_provider.Metrics.circuit_state_to_int state)
  in
  Prometheus.set_gauge circuit_state_metric
    ~labels:
      [
        ("provider", provider);
        ("model", model_id);
        ("provider_key", provider_key);
      ]
    value

(** Canonical metric name for the unified fallback counter (§7.3.2 Zero
    Silent Failure). This is the single numerator across all fallback
    classes for the dashboard panel. *)
let fallback_triggered_metric = Prometheus.metric_fallback_triggered

(** Emit a fallback observation to the unified counter.
    [kind]   one of: cascade_empty | capability_drop | cli_unsupported
                   | provider_error_fallback | …
    [detail] free-form drill-down (rejection_reason, target provider,
             dropped field, …). Cardinality bounded by callers. *)
let emit_fallback_triggered ~kind ~detail =
  Prometheus.inc_counter fallback_triggered_metric
    ~labels:[("kind", kind); ("detail", detail)]
    ()

(** Per-HTTP-request latency histogram.  Distinct from
    [masc_llm_inference_duration_seconds] (turn-scope, populated by the
    keeper AfterTurn hook): this metric is per provider HTTP call, so
    streaming retries / cascade fallbacks each add an observation.

    Populated unconditionally by the OAS [on_request_end] callback,
    which fires for every completed HTTP request regardless of whether
    the AfterTurn hook later runs.  Provides redundant latency
    observability so a broken hook does not blank out the dashboard. *)
let request_latency_metric = Prometheus.metric_llm_provider_request_latency
let request_latency_clamped_metric =
  Prometheus.metric_llm_provider_request_latency_clamped

let request_latency_seconds ~latency_ms =
  let latency_ms = Stdlib.max 1 latency_ms in
  Float.of_int latency_ms /. 1000.0

let emit_request_latency_clamped ~provider ~model_id ~reason =
  Prometheus.inc_counter request_latency_clamped_metric
    ~labels:[("provider", provider); ("model", model_id); ("reason", reason)]
    ()

(** Emit a single latency observation to the Prometheus histogram.

    Exposed so that per-call metrics sinks (e.g. the cascade-observation
    capture in [Cascade_legacy_runner]) can forward [on_request_end] to the
    same histogram without duplicating the label shape.  This is the
    single source of truth for the label key names. *)
let emit_request_latency ?provider ~model_id ~latency_ms () =
  let resolution = resolve_provider_for_latency ?provider ~model_id () in
  let provider_label = provider_label_of_resolution resolution in
  (* The clamped counter is the operator surface for *both* invalid
     [latency_ms] inputs and unknown-provider attribution. Two distinct
     [reason] label values keep the bug classes separable. *)
  (match resolution with
   | Provider_unknown_no_model_id ->
     emit_request_latency_clamped
       ~provider:provider_label
       ~model_id
       ~reason:"provider_unknown_no_model_id"
   | Provider_unknown_cache_miss _ ->
     emit_request_latency_clamped
       ~provider:provider_label
       ~model_id
       ~reason:"provider_unknown_cache_miss"
   | Provider_explicit _ | Provider_cached _ -> ());
  if latency_ms <= 0 then
    emit_request_latency_clamped
      ~provider:provider_label
      ~model_id
      ~reason:"non_positive_latency_ms";
  let seconds = request_latency_seconds ~latency_ms in
  Prometheus.observe_histogram request_latency_metric
    ~labels:[("provider", provider_label); ("model", model_id)] seconds

(** Build the OAS Metrics.t sink.

    Currently wired through:
    - [on_cache_hit]    → masc_llm_provider_cache_hits_total
    - [on_cache_miss]   → masc_llm_provider_cache_misses_total
    - [on_request_start] → masc_llm_provider_requests_started_total
    - [on_http_status]   → masc_llm_provider_http_status_total
    - [on_request_end]   → masc_llm_provider_request_latency_seconds
    - [on_error]        → masc_llm_provider_errors_total
    - [on_retry]        → masc_llm_provider_retries_total
    - [on_circuit_state] → masc_llm_provider_circuit_state
    - [on_token_usage]  → masc_llm_provider_{input,output}_tokens_total
    - [on_tool_calls]   → masc_llm_provider_tool_calls_total
    - [on_streaming_first_chunk] → masc_llm_provider_streaming_first_chunk_seconds
    - [on_streaming_chunk] → masc_llm_provider_streaming_inter_chunk_seconds *)
let make_sink () : Llm_provider.Metrics.t =
  Oas_compat.Metrics.make
    ~on_cache_hit:emit_cache_hit
    ~on_cache_miss:emit_cache_miss
    ~on_request_start:emit_request_start
    ~on_http_status:(fun ~provider ~model_id ~status ->
      emit_http_status ~provider ~model_id ~status)
    ~on_request_end:(fun ~model_id ~latency_ms ->
      match latency_ms with
      | Some latency_ms -> emit_request_latency ~model_id ~latency_ms ()
      | None -> ())
    ~on_capability_drop:(fun ~model_id ~field ->
      emit_capability_drop ~model_id ~field)
    ~on_error:(fun ~model_id ~error -> emit_error ~model_id ~error)
    ~on_retry:emit_retry
    ~on_circuit_state:emit_circuit_state
    ~on_token_usage:emit_token_usage
    ~on_tool_calls:emit_tool_calls
    ~on_streaming_first_chunk:emit_streaming_first_chunk
    ~on_streaming_chunk:emit_streaming_chunk
    ()

(** Install the sink as the process-wide default.  Idempotent — calling
    [install ()] multiple times overwrites the previous sink with a
    freshly-constructed one pointing at the same counter.  Intended to
    be called once during server bootstrap, before the first keeper
    turn fires an LLM call. *)
let install () : unit =
  Llm_provider.Metrics.set_global (make_sink ())
