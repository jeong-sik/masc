(** Prometheus-Compatible Metrics for masc-mcp

    Provides lightweight metrics collection and Prometheus text format export.

    Usage:
    {[
      let () = Prometheus.inc_counter "masc_tasks_total" ~labels:[("status", "completed")]
      let () = Prometheus.set_gauge "masc_active_agents" 5.0
      let text = Prometheus.to_prometheus_text ()
    ]}

    @since 0.4.0
*)

(** {1 Metric Types} *)

type label = string * string

type metric_type =
  | Counter
  | Gauge
  | Histogram

type metric = {
  name: string;
  help: string;
  metric_type: metric_type;
  mutable value: float;
  labels: label list;
}

(** {1 Global Metrics Store}

    [metrics] is updated from any fiber on any domain — LLM telemetry,
    keeper heartbeats, SSE bookkeeping, HTTP handlers. The previous
    implementation used a bare [Hashtbl.t] with [find_opt] + [add] which
    has two race windows:

    1. TOCTOU on registration: two fibers call [inc_counter] on a new
       key, both see [None], both [Hashtbl.add] — duplicate entries in
       the table.
    2. Non-atomic float update: [m.value <- m.value +. delta] reads,
       adds, writes without a memory barrier; two concurrent increments
       can both observe the same old value.

    We serialise every read and write path through [Stdlib.Mutex].
    Choice of primitive: operations must work during module
    initialisation ([let () = init ()] at EOF runs before any Eio
    scheduler exists), must hold across OCaml 5 domains (Executor_pool
    workers), and are individually cheap (a Hashtbl op + a float add) so
    the lock is never held long. [Stdlib.Mutex] fits all three. *)

let metrics : (string, metric) Hashtbl.t = Hashtbl.create 64
let metrics_mutex = Stdlib.Mutex.create ()

let with_lock f =
  Stdlib.Mutex.lock metrics_mutex;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock metrics_mutex)
    f

(** {1 Metric Registration} *)

let register_counter ~name ~help ?(labels=[]) () =
  let key = name ^ (List.fold_left (fun acc (k, v) -> acc ^ k ^ v) "" labels) in
  with_lock (fun () ->
    if not (Hashtbl.mem metrics key) then
      Hashtbl.add metrics key { name; help; metric_type = Counter; value = 0.0; labels })

let register_gauge ~name ~help ?(labels=[]) () =
  let key = name ^ (List.fold_left (fun acc (k, v) -> acc ^ k ^ v) "" labels) in
  with_lock (fun () ->
    if not (Hashtbl.mem metrics key) then
      Hashtbl.add metrics key { name; help; metric_type = Gauge; value = 0.0; labels })

let register_histogram ~name ~help ?(labels=[]) () =
  let key = name ^ (List.fold_left (fun acc (k, v) -> acc ^ k ^ v) "" labels) in
  with_lock (fun () ->
    if not (Hashtbl.mem metrics key) then
      Hashtbl.add metrics key { name; help; metric_type = Histogram; value = 0.0; labels })

(** {1 Metric Updates} *)

let inc_counter name ?(labels=[]) ?(delta=1.0) () =
  let key = name ^ (List.fold_left (fun acc (k, v) -> acc ^ k ^ v) "" labels) in
  with_lock (fun () ->
    match Hashtbl.find_opt metrics key with
    | Some m -> m.value <- m.value +. delta
    | None ->
        Hashtbl.add metrics key {
          name;
          help = name;
          metric_type = Counter;
          value = delta;
          labels;
        })

let set_gauge name ?(labels=[]) value =
  let key = name ^ (List.fold_left (fun acc (k, v) -> acc ^ k ^ v) "" labels) in
  with_lock (fun () ->
    match Hashtbl.find_opt metrics key with
    | Some m -> m.value <- value
    | None ->
        Hashtbl.add metrics key {
          name;
          help = name;
          metric_type = Gauge;
          value;
          labels;
        })

let inc_gauge name ?(labels=[]) ?(delta=1.0) () =
  let key = name ^ (List.fold_left (fun acc (k, v) -> acc ^ k ^ v) "" labels) in
  with_lock (fun () ->
    match Hashtbl.find_opt metrics key with
    | Some m -> m.value <- m.value +. delta
    | None ->
        Hashtbl.add metrics key {
          name;
          help = name;
          metric_type = Gauge;
          value = delta;
          labels;
        })

let dec_gauge name ?(labels=[]) ?(delta=1.0) () =
  inc_gauge name ~labels ~delta:(-.delta) ()

(** Get current metric value by name + labels (if any). *)
let get_metric_value name ?(labels=[]) () =
  let key = name ^ (List.fold_left (fun acc (k, v) -> acc ^ k ^ v) "" labels) in
  with_lock (fun () ->
    Hashtbl.find_opt metrics key |> Option.map (fun m -> m.value))

let metric_value_or_zero name ?(labels=[]) () =
  get_metric_value name ~labels () |> Option.value ~default:0.0

let metric_total name =
  with_lock (fun () ->
    Hashtbl.fold
      (fun _ (m : metric) acc ->
        if String.equal m.name name then acc +. m.value else acc)
      metrics 0.0)

(** Observe a histogram value.
    Tracks cumulative sum in the metric value; a matching _count counter
    is auto-created for computing averages. *)
let observe_histogram name ?(labels=[]) value =
  let key = name ^ (List.fold_left (fun acc (k, v) -> acc ^ k ^ v) "" labels) in
  let count_key = name ^ "_count" ^ (List.fold_left (fun acc (k, v) -> acc ^ k ^ v) "" labels) in
  with_lock (fun () ->
    (match Hashtbl.find_opt metrics key with
     | Some m -> m.value <- m.value +. value
     | None ->
         Hashtbl.add metrics key {
           name; help = name; metric_type = Histogram; value; labels;
         });
    (match Hashtbl.find_opt metrics count_key with
     | Some m -> m.value <- m.value +. 1.0
     | None ->
         Hashtbl.add metrics count_key {
           name = name ^ "_count"; help = name ^ " observation count";
           metric_type = Counter; value = 1.0; labels;
         }))

(** {1 Metric Name Constants}

    Exported so registration here and [inc_counter] / [set_gauge]
    call-sites in the keeper modules share a single source of truth.
    Without this, a typo on either side produces a dead series with
    no build error (the counter silently drifts to a new key).

    Convention: constant name drops the Prometheus convention suffix
    ([_total] for counters), full metric name lives on the right-hand
    side. Consumers import [Prometheus.<constant>] so the compiler
    catches typos. *)

(* Keeper turn lifecycle (registered in init, incremented in
   keeper_unified_turn.ml). *)
let metric_keeper_turns = "masc_keeper_turns_total"
let metric_keeper_input_tokens = "masc_keeper_input_tokens_total"
let metric_keeper_output_tokens = "masc_keeper_output_tokens_total"
let metric_keeper_cache_creation_tokens =
  "masc_keeper_cache_creation_tokens_total"
let metric_keeper_cache_read_tokens =
  "masc_keeper_cache_read_tokens_total"
let metric_keeper_usage_anomalies =
  "masc_keeper_usage_anomalies_total"

(* #10047: [append_metrics_snapshot] failures in [keeper_turn.ml] and
   [keeper_unified_turn.ml] used to be log-only, masking state/metric
   divergence. Surface as a counter so dashboards can alert on silent
   metric drops and operators stop trusting metric jsonl as ground
   truth when keepers are running. *)
let metric_keeper_metric_emit_dropped =
  "masc_keeper_metric_emit_dropped_total"

(* #9953: counter of observed [context_max] values labelled by
   [keeper, model_used, resolved_model_id, context_max_bucket].
   The bucket label collapses raw token counts into a small set
   of strings ("64k" | "128k" | "200k" | "256k" | "1m" | "other"
   | "zero") so the cardinality stays bounded.

   Operators use this counter to detect drift: the same
   ([model_used], [resolved_model_id]) pair should land in ONE
   bucket; observing two buckets means the resolution path
   produced different ceilings on different turns.  The 42% /
   17% / 41% split for [claude_code:auto] reported in #9953 is
   directly visible here as three counter rows. *)
let metric_keeper_context_max_observed =
  "masc_keeper_context_max_observed_total"

(* #10121: keeper turn livelock observer.  Each turn-start
   bumps [metric_keeper_turn_starts]; a re-start of the SAME
   turn id (turn counter did not advance) bumps the dedicated
   [metric_keeper_turn_reattempts].  Operators alert on
   [rate(masc_keeper_turn_reattempts_total[5m]) > 0] and pick
   up stuck-turn pairs without grepping log lines.  See also
   [metric_keeper_turn_regressions] when the FSM moves to a
   strictly LOWER turn id (very unusual; indicative of
   write_meta race losing an in-memory counter increment,
   #9733). *)
let metric_keeper_turn_starts = "masc_keeper_turn_starts_total"
let metric_keeper_turn_reattempts = "masc_keeper_turn_reattempts_total"
let metric_keeper_turn_regressions = "masc_keeper_turn_regressions_total"

(* #9943: per-keeper turn-latency bucket counter.  Each completed
   turn lands in exactly one [latency_bucket] label so a Prometheus
   query like
     rate(masc_keeper_turn_latency_bucket_total{bucket="600-1200s"}[5m])
   directly surfaces slow-turn keepers without needing the JSONL
   ledger.  20-minute turns from oas_timeout_budget exhaustion
   (#9933, observed 1,204,542 ms = 20 min on taskmaster
   2026-04-24) appear in the [over_1200s] bucket and operators can
   alert on its rate.  Existing [masc_llm_inference_duration_seconds]
   histogram is labelled by [model] only (per-LLM-call latency); this
   counter labels by [keeper] (per-turn latency) and uses bucket
   strings instead of histogram observations so dashboards can group
   counts directly. *)
let metric_keeper_turn_latency_bucket =
  "masc_keeper_turn_latency_bucket_total"

(* #10125: keeper supervisor sweep observability.

   The supervisor sweep is a Pulse loop that recovers crashed
   keepers.  When the loop fails to start (or stops), the fleet
   silently dies — keepers exit on cascade exhaustion and nobody
   restarts them.  Observed 2026-04-24: 14 keepers dead, supervisor
   "started" log line missing for 4h+ across a server restart.

   Two metrics surface the sweep liveness directly so dashboards
   can alert on absence instead of relying on a log grep:

   - [metric_keeper_supervisor_sweep_starts_total] — increments
     once each time [start_supervisor_sweep] actually creates a
     Pulse (i.e., once per process unless explicitly stopped).
     If the counter does not advance after a server restart, the
     supervisor never came up.
   - [metric_keeper_supervisor_last_sweep_unixtime] — gauge updated
     on every successful sweep beat.  Operator alert:
     [time() - masc_keeper_supervisor_last_sweep_unixtime > 90]
     means the sweep is stalled (default sweep interval is 30s). *)
let metric_keeper_supervisor_sweep_starts =
  "masc_keeper_supervisor_sweep_starts_total"
let metric_keeper_supervisor_last_sweep_unixtime =
  "masc_keeper_supervisor_last_sweep_unixtime"


(* Keeper compaction (keeper_compact_policy.ml, tool_keeper.ml). *)
let metric_keeper_compactions = "masc_keeper_compactions_total"
let metric_keeper_compaction_ratio_change =
  "masc_keeper_compaction_ratio_change"
let metric_keeper_compaction_saved_tokens =
  "masc_keeper_compaction_saved_tokens_total"
let metric_keeper_operator_compact = "masc_keeper_operator_compact_total"
let metric_keeper_operator_clear = "masc_keeper_operator_clear_total"

(* Keeper keepalive (keeper_keepalive.ml). *)
let metric_keeper_heartbeat_successes =
  "masc_keeper_heartbeat_successes_total"
let metric_keeper_heartbeat_failures =
  "masc_keeper_heartbeat_failures_total"
let metric_keeper_tool_call_duration =
  "masc_keeper_tool_call_duration_seconds"
let metric_keeper_write_meta_failures =
  "masc_keeper_write_meta_failures_total"
let metric_keeper_lifecycle_dispatch_rejections =
  "masc_keeper_lifecycle_dispatch_rejections_total"
let metric_keeper_paused_state_persist_errors =
  "masc_keeper_paused_state_persist_errors_total"
let metric_keeper_unexpected_tool_partial_tolerance =
  "masc_keeper_unexpected_tool_partial_tolerance_total"
(* #10091: [require_tool_use] contract violations labelled by
   [has_current_task] (true = #10091's active-task path that
   [#10031] intentionally left strict, false = the no-task path
   that [#10031] relaxed to [Auto]) and by fine-grained
   [contract_status] ([passive_only], [needs_execution_progress],
   [claim_only_after_owned_task], [tool_surface_mismatch],
   [missing_required_tool_use]).  The fleet histogram of
   (keeper, contract_status) pairs tells the operator which
   keeper tool_presets need reshaping for the current task mix
   without masking the strict gate. *)
let metric_keeper_require_tool_use_violations =
  "masc_keeper_require_tool_use_violations_total"
let metric_keeper_tool_alias_canonicalizations =
  "masc_keeper_tool_alias_canonicalizations_total"
let metric_keeper_profile_config_conflicts =
  "masc_keeper_profile_config_conflicts_total"
let metric_keeper_oas_timeout_classifications =
  "masc_keeper_oas_timeout_classifications_total"
let metric_persistence_read_drops =
  "masc_persistence_read_drops_total"

(* #10097: codex_cli provider cannot carry keeper-bound runtime MCP
   tools that need request-scoped auth headers.  Every time
   oas_worker_exec_transport strips such a tool, this counter
   increments with the tool name so dashboards can track WHICH
   tools are being omitted and at WHAT rate.  Paired with a
   once-per-session WARN log ([fingerprint]-deduplicated) so the
   operator sees the structural fact exactly once while the
   counter carries the frequency signal. *)
let metric_codex_cli_mcp_tool_omission =
  "masc_codex_cli_mcp_tool_omission_total"

(* #10094: per-caller counter for [Masc_oas_bridge.run_safe]
   timeouts.  The [caller] string supplied at the run_safe entry
   point lets the operator see WHICH caller is timing out at
   WHICH configured budget without grepping warn-level log
   lines.  Paired with per-caller env-overridable defaults in
   [Env_config_oas_bridge] so 60s "fantasy" budgets in
   [auto_responder] / [dashboard_provider_runs] no longer
   silently masquerade as the same class of event as
   intentional 120s/180s budgets in autoresearch / deep_review. *)
let metric_oas_bridge_timeout =
  "masc_oas_bridge_timeout_total"


(* OAS SSE relay (oas_sse_bridge.ml). *)
let metric_oas_sse_relay_retries =
  "masc_oas_sse_relay_retries_total"
let metric_oas_sse_relay_drops =
  "masc_oas_sse_relay_drops_total"
let metric_oas_sse_relay_queue_depth =
  "masc_oas_sse_relay_queue_depth"

(* MCP tool schema budget (set once at boot from mcp_server_eio.ml
   via [set_tool_schema_stats]). *)
let metric_mcp_tool_schema_count = "masc_mcp_tool_schema_count"
let metric_mcp_tool_schema_tokens_approx =
  "masc_mcp_tool_schema_tokens_approx"

(* Transport metrics — used in transport_metrics.ml. *)
let metric_sse_sessions = "masc_sse_sessions_total"
let metric_sse_broadcast_duration = "masc_sse_broadcast_duration_seconds"
let metric_sse_broadcast_events = "masc_sse_broadcast_events_total"
let metric_sse_stream_queue_depth = "masc_sse_stream_queue_depth"
let metric_sse_queue_depth_avg = "masc_sse_queue_depth_avg"
let metric_sse_queue_depth_max = "masc_sse_queue_depth_max"
let metric_sse_external_subscribers = "masc_sse_external_subscribers_total"
let metric_grpc_active_streams = "masc_grpc_active_streams_total"
let metric_grpc_heartbeat_latency = "masc_grpc_heartbeat_latency_seconds"
let metric_grpc_subscribers = "masc_grpc_subscribers_total"
let metric_grpc_events_delivered = "masc_grpc_events_delivered_total"
let metric_grpc_events_dropped = "masc_grpc_events_dropped_total"
let metric_ws_sessions = "masc_ws_sessions_total"
let metric_ws_parse_cache_hits = "masc_ws_parse_cache_hits_total"
let metric_ws_parse_cache_misses = "masc_ws_parse_cache_misses_total"
let metric_ws_bytes_cache_hits = "masc_ws_bytes_cache_hits_total"
let metric_ws_bytes_cache_misses = "masc_ws_bytes_cache_misses_total"
let metric_ws_client_buffered_bytes = "masc_ws_client_buffered_bytes"
let metric_ws_client_acks = "masc_ws_client_acks_total"
let metric_ws_throttled_deliveries = "masc_ws_throttled_deliveries_total"

(* Admission queue metrics — used in admission_queue_metrics.ml. *)
let metric_inference_queue_depth = "masc_inference_queue_depth"
let metric_inference_queue_inflight = "masc_inference_queue_inflight"
let metric_inference_queue_acquired = "masc_inference_queue_acquired_total"
let metric_inference_queue_wait = "masc_inference_queue_wait_seconds"
let metric_inference_queue_cancelled = "masc_inference_queue_cancelled_total"
let metric_inference_queue_max_concurrent = "masc_inference_queue_max_concurrent"

(* Agent health metrics — used in transport_metrics.ml. *)
let metric_agent_heartbeat_age_seconds = "masc_agent_heartbeat_age_seconds"
let metric_agent_stale_total = "masc_agent_stale_total"

(* Process-level FD gauges — used in init() and update_fd_gauges. *)
let metric_open_fds = "masc_process_open_fds"
let metric_fd_warn_threshold = "masc_process_fd_warn_threshold"

(* Core counters / gauges — used outside init. *)
let metric_mcp_requests = "masc_mcp_requests_total"
let metric_llm_inference_duration = "masc_llm_inference_duration_seconds"
(* Throughput histograms — derived from Agent_sdk inference_telemetry.timings.
   Split from masc_llm_inference_duration_seconds because wall-clock latency
   mixes prefill and decode phases; operators need them separately to tell
   "prompt ingestion is slow" apart from "generation is slow". Silent when
   the backend does not emit timings (Anthropic/Gemini). *)
let metric_llm_prompt_tok_per_sec = "masc_llm_prompt_tok_per_sec"
let metric_llm_decode_tok_per_sec = "masc_llm_decode_tok_per_sec"
let metric_after_turn_hook = "masc_after_turn_hook_total"
let metric_after_turn_telemetry_missing =
  "masc_after_turn_telemetry_missing_total"
let metric_after_turn_telemetry_zero_latency =
  "masc_after_turn_telemetry_zero_latency_total"
let metric_tasks = "masc_tasks_total"
let metric_errors = "masc_errors_total"
let metric_error_events = "masc_error_events_total"
let metric_active_agents = "masc_active_agents"
let metric_pending_tasks = "masc_pending_tasks"
let metric_uptime_seconds = "masc_uptime_seconds"
let metric_sse_connections_active = "masc_sse_connections_active"
let metric_sse_reconnects = "masc_sse_reconnects_total"
let metric_sse_idle_evictions = "masc_sse_idle_evictions_total"
let metric_sse_capacity_evictions = "masc_sse_capacity_evictions_total"
let metric_sse_write_failures = "masc_sse_write_failures_total"
let metric_sse_rejects = "masc_sse_rejects_total"
let metric_provider_prefix_cache_creation_tokens =
  "masc_provider_prefix_cache_creation_tokens_total"
let metric_provider_prefix_cache_read_tokens =
  "masc_provider_prefix_cache_read_tokens_total"
let metric_tool_call = "masc_tool_call_total"
let metric_tool_call_duration = "masc_tool_call_duration_seconds"
let metric_llm_provider_http_status = "masc_llm_provider_http_status_total"
let metric_llm_provider_request_latency =
  "masc_llm_provider_request_latency_seconds"

(* Domain-specific counters not yet constant-ised. *)
let metric_anti_rationalization_fallback =
  "masc_anti_rationalization_fallback_total"
(* #10113: per-pattern + per-decision counter for the gate 2
   excuse substring detector.  [decision] distinguishes the
   three reachable outcomes:
   - [advisory_to_llm]: pattern detected, default mode → LLM evaluates
     with the pattern as a heuristic hint;
   - [terminal_reject]: pattern detected,
     [MASC_ANTI_RATIONALIZATION_GATE2_FAIL_CLOSED=true] →
     historical local reject (operator opt-in);
   - [advisory_safety_net_reject]: pattern detected, advisory
     mode, but the LLM evaluator was unavailable so the
     pattern was upgraded to a Reject (LLM-down safety net).
   Lets the operator measure false-positive vs true-positive
   ratio per pattern across deployments without grepping logs. *)
let metric_anti_rationalization_excuse_pattern =
  "masc_anti_rationalization_excuse_pattern_total"
let metric_board_truncated_posts = "masc_board_truncated_posts_total"
let metric_cascade_strategy_decisions = "masc_cascade_strategy_decisions_total"
let metric_cascade_capacity_events = "masc_cascade_capacity_events_total"
let metric_keeper_invariant_violations = "masc_keeper_invariant_violations_total"
let metric_oas_bus_subscriber_stream_depth = "masc_oas_bus_subscriber_stream_depth"
let metric_oas_bus_publish_block_seconds = "masc_oas_bus_publish_block_seconds_total"
let metric_oas_bus_publish = "masc_oas_bus_publish_total"
let metric_runtime_ollama_probe_generate_skips =
  "masc_runtime_ollama_probe_generate_skips_total"

(* #10130: boot-time sweep of [save_file_atomic] orphan temp
   files.  Labels: [size_class = empty | with_data].  The
   [with_data] rate is the interesting operator signal — each
   non-zero orphan represents a silent atomic-save failure
   (SIGKILL / ENFILE mid-write) that dropped the payload. *)
let metric_fs_atomic_orphans_cleaned =
  "masc_fs_atomic_orphans_cleaned_total"

(** {1 Built-in Metrics} *)

let init () =
  (* Module-level init runs before Eio context exists.
     Single-threaded at load time — bypass mutex. *)
  let add name help mt =
    let key = name in
    if not (Hashtbl.mem metrics key) then
      Hashtbl.add metrics key { name; help; metric_type = mt; value = 0.0; labels = [] }
  in
  add metric_mcp_requests "Total MCP requests received" Counter;
  add metric_llm_inference_duration "LLM inference request duration in seconds" Histogram;
  add metric_llm_prompt_tok_per_sec
    "LLM prefill (prompt_eval) throughput in tokens/second from \
     inference_telemetry.timings.prompt_per_second. Per-turn observation \
     labelled by model and provider_kind. Silent for providers that do not \
     emit timings (Anthropic/Gemini); use masc_after_turn_telemetry_missing_total \
     to detect that." Histogram;
  add metric_llm_decode_tok_per_sec
    "LLM decode (predicted) throughput in tokens/second from \
     inference_telemetry.timings.predicted_per_second. Per-turn observation \
     labelled by model and provider_kind. Distinct from \
     masc_llm_prompt_tok_per_sec: decode rate is the hardware generation \
     speed, prompt rate is the prefill ingestion speed." Histogram;
  add metric_after_turn_hook
    "Times the keeper AfterTurn hook ran (labeled by model). Divergence from \
     masc_llm_inference_duration_seconds_count identifies missing telemetry." Counter;
  add metric_after_turn_telemetry_missing
    "AfterTurn responses where response.telemetry was None." Counter;
  add metric_after_turn_telemetry_zero_latency
    "AfterTurn responses where telemetry was present but request_latency_ms was 0." Counter;
  add metric_tasks "Total tasks processed" Counter;
  add metric_errors "Total errors" Counter;
  add metric_error_events
    "Error events by type (parsing, missing_config, etc.)" Counter;
  add metric_active_agents "Currently active agents" Gauge;
  add metric_pending_tasks "Tasks waiting to be claimed" Gauge;
  add metric_uptime_seconds "Server uptime in seconds" Gauge;
  add metric_sse_connections_active "Active SSE connections" Gauge;
  add metric_sse_reconnects "Total SSE reconnects (same session reattached)" Counter;
  add metric_sse_idle_evictions "Total SSE clients evicted by idle reaper" Counter;
  add metric_sse_capacity_evictions "Total SSE clients evicted due to max client capacity" Counter;
  add metric_sse_write_failures "Total SSE write failures by reason" Counter;
  add metric_sse_rejects "Total SSE connections rejected by storm guard" Counter;
  (* #9953: context_max distribution per keeper / model / resolved
     model.  Operators query [count by (model_used, resolved_model_id)
     (masc_keeper_context_max_observed_total)] to detect drift —
     a count > 1 indicates the same model resolved to different
     ceilings on different turns. *)
  add metric_keeper_context_max_observed
    "Total observed keeper context_max values, bucketed (labels: keeper, \
     model_used, resolved_model_id, context_max_bucket=64k|128k|200k|256k|1m|other|zero)"
    Counter;
  (* #10121: keeper turn livelock observer counters.  Operator
     alert: rate(masc_keeper_turn_reattempts_total[5m]) > 0
     surfaces stuck (keeper, turn) pairs without grepping logs. *)
  add metric_keeper_turn_starts
    "Total keeper turn starts (every dispatch increments, regardless of \
     whether the turn id is new or repeated)"
    Counter;
  add metric_keeper_turn_reattempts
    "Total keeper turn re-attempts: same turn id started again before \
     the counter advanced (livelock signal — #10121)"
    Counter;
  add metric_keeper_turn_regressions
    "Total keeper turn regressions: turn id moved to a strictly LOWER \
     value than previously observed (write_meta race losing an in-memory \
     counter increment — #9733 / #10121)"
    Counter;
  (* #9943: per-keeper turn latency bucket distribution.  Each
     completed turn increments exactly one bucket.  Bucket vocabulary
     [under_60s | 60-300s | 300-600s | 600-1200s | over_1200s]. *)
  add metric_keeper_turn_latency_bucket
    "Total keeper turn completions, bucketed by latency (labels: keeper, \
     bucket=under_60s|60-300s|300-600s|600-1200s|over_1200s)"
    Counter;
  (* #10125: supervisor sweep liveness.  Counter increments on
     each [start_supervisor_sweep] that actually creates a Pulse;
     gauge advances on every successful sweep beat. *)
  add metric_keeper_supervisor_sweep_starts
    "Total times keeper supervisor sweep Pulse was started (labels: base_path)"
    Counter;
  add metric_keeper_supervisor_last_sweep_unixtime
    "Wall-clock unixtime of the most recent successful supervisor \
     sweep beat (labels: base_path).  Stale (> 2 × interval) means \
     the sweep stalled."
    Gauge;
  (* Keeper compaction metrics — emitted by keeper_compact_policy.ml *)
  add metric_keeper_compactions
    "Total keeper compactions performed" Counter;
  add metric_keeper_compaction_ratio_change
    "Context ratio change after compaction (pre - post)" Gauge;
  add metric_keeper_compaction_saved_tokens
    "Total tokens removed by keeper context compaction" Counter;
  (* Operator-initiated overflow recovery — emitted by tool_keeper.ml *)
  add metric_keeper_operator_compact
    "Total operator-invoked masc_keeper_compact calls (labels: result=ok|no_checkpoint|precondition|not_found)" Counter;
  add metric_keeper_operator_clear
    "Total operator-invoked masc_keeper_clear calls (labels: preserve_system=true|false)" Counter;
  (* Keeper heartbeat metrics — emitted by keeper_keepalive.ml *)
  add metric_keeper_heartbeat_successes
    "Total keeper heartbeat successes" Counter;
  add metric_keeper_heartbeat_failures
    "Total keeper heartbeat failures" Counter;
  register_histogram ~name:metric_keeper_tool_call_duration
    ~help:"Keeper tool call latency in seconds, labeled by keeper, provider, tool, and outcome" ();
  add metric_provider_prefix_cache_creation_tokens
    "Total provider prefix cache creation tokens (Anthropic)" Counter;
  add metric_provider_prefix_cache_read_tokens
    "Total provider prefix cache read tokens (Anthropic)" Counter;
  add metric_tool_call
    "Total keeper tool calls labeled by provider, tool, and outcome" Counter;
  register_histogram ~name:metric_tool_call_duration
    ~help:"Tool call latency in seconds" ();
  (* Inference admission queue metrics *)
  add metric_inference_queue_inflight
    "Concurrent inference calls holding an admission permit" Gauge;
  add metric_inference_queue_depth
    "Callers waiting in the admission queue" Gauge;
  add metric_inference_queue_max_concurrent
    "Configured max concurrent admission permits" Gauge;
  add metric_inference_queue_acquired
    "Total admission permits acquired" Counter;
  add metric_inference_queue_cancelled
    "Total admission waits cancelled by fiber cancellation" Counter;
  register_histogram ~name:metric_inference_queue_wait
    ~help:"Time waiting in admission queue before exchanging for permit" ();
  (* LLM provider HTTP response counter — emitted by Llm_metric_bridge
     via the OAS Metrics.t on_http_status hook.  Labels are populated
     dynamically per call; no initial registration with zero-value rows
     is needed because inc_counter auto-creates the label series on
     first observation. *)
  add metric_llm_provider_http_status
    "Total HTTP responses from LLM providers, labeled by provider, model, and status code"
    Counter;
  (* Orphan metrics — used via inc_counter/set_gauge but previously
     never registered.  Auto-create still works, but registering here
     gives them a HELP description in /metrics output and a zero-value
     baseline so dashboards see "0" instead of "no data" before the
     first observation. *)
  add metric_keeper_write_meta_failures
    "Total keeper meta-file write failures, labeled by keeper and phase"
    Counter;
  add metric_keeper_lifecycle_dispatch_rejections
    "Total post-turn lifecycle dispatch rejections, labeled by event"
    Counter;
  add metric_keeper_paused_state_persist_errors
    "Total keeper paused-state persistence failures, labeled by phase \
     (boot_resume_check|boot_resume_persist) and reason (read_meta_error|meta_missing)"
    Counter;
  add metric_keeper_unexpected_tool_partial_tolerance
    "Total keeper turns that tolerated unexpected tool names because at least \
     one valid keeper tool call was present. Labeled by keeper_name and \
     logged=true|false so WARN suppression remains observable."
    Counter;
  add metric_keeper_tool_alias_canonicalizations
    "Total observed LLM-facing tool names canonicalized to keeper internal \
     tool names. Labeled by alias_kind, public_tool, and canonical_tool."
    Counter;
  add metric_keeper_profile_config_conflicts
    "Total keeper profile config conflicts between persona defaults and TOML \
     overlays. Labeled by field, resolution, and logged=true|false."
    Counter;
  add metric_keeper_oas_timeout_classifications
    "Total keeper OAS timeout classifications. Labeled by \
     classification=transient_network|structural_budget|other_timeout."
    Counter;
  add metric_persistence_read_drops
    "Total persisted read-model entries dropped during filesystem scans, \
     labeled by surface and reason"
    Counter;
  add metric_oas_sse_relay_retries
    "Total OAS SSE relay retry attempts, labeled by failed stage"
    Counter;
  add metric_oas_sse_relay_drops
    "Total OAS SSE relay drops after retries or queue pressure, labeled by stage"
    Counter;
  add metric_oas_sse_relay_queue_depth
    "Current in-memory OAS SSE relay retry queue depth"
    Gauge;
  add metric_board_truncated_posts
    "Total board posts truncated due to size limits"
    Counter;
  add metric_anti_rationalization_fallback
    "Total anti-rationalization fallbacks fired (verifier LLM unavailable), labeled by mode and cascade"
    Counter;
  add metric_anti_rationalization_excuse_pattern
    "Total anti-rationalization excuse pattern detections at gate 2, \
     labeled by pattern and decision (advisory_to_llm | terminal_reject \
     | advisory_safety_net_reject) — #10113"
    Counter;
  add metric_agent_heartbeat_age_seconds
    "Maximum observed heartbeat age across active agents (seconds)"
    Gauge;
  add metric_agent_stale_total
    "Total agents marked stale due to missed heartbeats"
    Counter;
  register_histogram ~name:metric_llm_provider_request_latency
    ~help:"Per-HTTP-request LLM latency from OAS on_request_end callback. \
           Independent from masc_llm_inference_duration_seconds (turn-scope) — \
           this fires per provider HTTP call regardless of keeper hook health." ();
  (* Process-level resource gauges.  Sampled on every /metrics scrape via
     [update_fd_gauges] so a monotonic ramp (fd leak) is visible in the
     time series before it crosses the OS limit and crashes the server.
     Evidence: 2026-04-16 production incident, 4029 CLOSE_WAIT sockets
     accumulated before the accept() path started failing. *)
  add metric_open_fds
    "Approximate count of open file descriptors for the server process \
     (derived from /dev/fd). Ramp indicates a socket/file leak." Gauge;
  add metric_fd_warn_threshold
    "Threshold above which open_fds triggers a one-shot WARN log." Gauge;
  (* Per-keeper turn outcome + token counters.  Labels are populated
     dynamically via inc_counter; no upfront registration needed.
     Covers issues #7495 (cost/token attribution) and #7519 (SLO). *)
  add metric_keeper_turns
    "Total keeper turns by outcome (labels: keeper_name, outcome=success|failure|budget_exhausted|mutation_boundary)"
    Counter;
  add metric_keeper_input_tokens
    "Cumulative input tokens per keeper turn (labels: keeper_name, model)"
    Counter;
  add metric_keeper_output_tokens
    "Cumulative output tokens per keeper turn (labels: keeper_name, model)"
    Counter;
  (* Anthropic / Bedrock prompt caching observability (#7469 Step 1).
     OAS already receives [cache_creation_input_tokens] and
     [cache_read_input_tokens] in every [api_usage]; these counters
     expose them to Prometheus so cache hit-rate and write cost are
     attributable per keeper + model. Populated dynamically via
     [inc_counter]; tools that never emit cache data (e.g. non-Anthropic
     providers) simply leave these at 0. Names are exported as module
     constants below so registration and call-sites cannot drift. *)
  add metric_keeper_cache_creation_tokens
    "Cumulative prompt-cache creation tokens per keeper turn (labels: keeper_name, model)"
    Counter;
  add metric_keeper_cache_read_tokens
    "Cumulative prompt-cache read tokens per keeper turn (labels: keeper_name, model)"
    Counter;
  add metric_keeper_usage_anomalies
    "Keeper turns whose reported usage was marked untrusted (labels: keeper_name, model, reason)"
    Counter;
  (* Tool schema budget gauges — set once at boot via
     [set_tool_schema_stats]. Covers #7483 Step 1. *)
  add metric_mcp_tool_schema_count
    "Number of tool schemas exposed to MCP clients" Gauge;
  add metric_mcp_tool_schema_tokens_approx
    "Approximate token count of all tool schemas combined (chars/4)"
    Gauge;
  (* OAS Event_bus backpressure observability (see oas_bus_instrument.ml).
     Label series are populated dynamically per subscriber_purpose. *)
  add metric_oas_bus_subscriber_stream_depth
    "Estimated OAS Event_bus per-subscriber stream depth, labeled by \
     subscriber_purpose. Indirect measure: publishes_matching_filter - \
     events_drained, tracked MASC-side for subscriptions created via \
     Oas_bus_instrument. OAS uses bounded Eio.Stream (default 256); values \
     approaching this cap indicate impending publish blocking."
    Gauge;
  add metric_oas_bus_publish_block_seconds
    "Cumulative seconds spent inside Oas.Event_bus.publish when routed \
     through Oas_bus_instrument.publish. A sustained ramp indicates a \
     subscriber drain loop has fallen behind and publishers are blocking \
     on Eio.Stream.add."
    Counter;
  add metric_oas_bus_publish
    "Total Oas.Event_bus.publish calls routed through \
     Oas_bus_instrument.publish."
    Counter;
  add metric_runtime_ollama_probe_generate_skips
    "Total Ollama runtime probes that intentionally skipped /api/generate. \
     Labeled by reason=status_only|model_unloaded|ps_error|no_effective_model|policy_skip."
    Counter;
  (* #10130: boot-time sweep of save_file_atomic orphans. *)
  add metric_fs_atomic_orphans_cleaned
    "Total save_file_atomic orphan temp files cleaned at boot \
     (labels: size_class=empty|with_data).  [with_data] rate > 0 \
     indicates silent atomic-save failures (SIGKILL / ENFILE) that \
     dropped payloads; moved to [<base_path>/.recovered/]."
    Counter;
  (* Transport metrics — registered here so transport_metrics.ml can use
     module constants instead of string literals. *)
  add metric_sse_sessions "Active SSE sessions by kind" Gauge;
  register_histogram ~name:metric_sse_broadcast_duration
    ~help:"Time to fan-out a broadcast to all SSE clients" ();
  add metric_sse_broadcast_events "Total SSE broadcast events emitted" Counter;
  add metric_sse_stream_queue_depth
    "Per-session SSE event stream queue depth" Gauge;
  add metric_sse_queue_depth_avg
    "Average SSE event queue depth across live sessions" Gauge;
  add metric_sse_queue_depth_max
    "Maximum SSE event queue depth across live sessions" Gauge;
  add metric_sse_external_subscribers
    "Active non-SSE subscribers bridged from the SSE fanout path" Gauge;
  add metric_grpc_active_streams "Active gRPC bidirectional streams" Gauge;
  register_histogram ~name:metric_grpc_heartbeat_latency
    ~help:"gRPC heartbeat round-trip latency" ();
  add metric_grpc_subscribers "Active gRPC Subscribe stream subscribers" Gauge;
  add metric_grpc_events_delivered "Total events delivered via gRPC streams" Counter;
  add metric_grpc_events_dropped
    "Events dropped by gRPC subscribers when the stream buffer is full \
     (capacity pressure — operator must investigate slow consumers)"
    Counter;
  add metric_ws_sessions "Active standalone WebSocket sessions" Gauge;
  add metric_ws_parse_cache_hits
    "WS dashboard delta parse cache hits (same event string reused across sessions)"
    Counter;
  add metric_ws_parse_cache_misses
    "WS dashboard delta parse cache misses (fresh JSON parse required)"
    Counter;
  add metric_ws_bytes_cache_hits
    "WS raw-SSE-forward Bytes cache hits (same event reused across sessions)"
    Counter;
  add metric_ws_bytes_cache_misses
    "WS raw-SSE-forward Bytes cache misses (fresh allocation required)"
    Counter;
  register_histogram ~name:metric_ws_client_buffered_bytes
    ~help:"Dashboard client WebSocket.bufferedAmount reported on each ack" ();
  add metric_ws_client_acks
    "Total dashboard/ack notifications received from WS clients"
    Counter;
  add metric_ws_throttled_deliveries
    "WS dashboard deliveries skipped because the client's last reported \
     bufferedAmount exceeded MASC_WS_CLIENT_BUFFER_LIMIT_BYTES"
    Counter

let start_time = Time_compat.now ()

let update_uptime () =
  set_gauge metric_uptime_seconds (Time_compat.now () -. start_time)

let fd_warn_threshold =
  Env_config_core.get_int ~default:3000 "MASC_FD_WARN_THRESHOLD" |> max 1

let () = set_gauge metric_fd_warn_threshold (float_of_int fd_warn_threshold)

let fd_warned_once = Atomic.make false

(** Returns 0 on non-Unix hosts where [/dev/fd] is unavailable. *)
let approximate_open_fd_count () =
  let candidates = ["/dev/fd"; "/proc/self/fd"] in
  let rec first_readable = function
    | [] -> None
    | path :: rest ->
        (try Some (path, Sys.readdir path)
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | Sys_error _ -> first_readable rest)
  in
  match first_readable candidates with
  | None -> 0
  | Some (_path, entries) ->
      max 0 (Array.length entries - 1)

let update_fd_gauges () =
  let count = approximate_open_fd_count () in
  set_gauge metric_open_fds (float_of_int count);
  if count >= fd_warn_threshold && not (Atomic.get fd_warned_once) then begin
    Atomic.set fd_warned_once true;
    Printf.eprintf
      "[WARN] [Server] process open fd count %d has reached warn \
       threshold %d — likely socket/file leak, investigate before \
       accept() starts failing with EMFILE.\n%!"
      count fd_warn_threshold
  end else if count < fd_warn_threshold / 2 then
    Atomic.set fd_warned_once false

let set_tool_schema_stats ~count ~approx_tokens =
  set_gauge metric_mcp_tool_schema_count (float_of_int count);
  set_gauge metric_mcp_tool_schema_tokens_approx (float_of_int approx_tokens)

(** {1 Prometheus Export} *)

let type_to_string = function
  | Counter -> "counter"
  | Gauge -> "gauge"
  | Histogram -> "histogram"

let labels_to_string = function
  | [] -> ""
  | labels ->
      let pairs = List.map (fun (k, v) ->
        Printf.sprintf "%s=\"%s\"" k (String.escaped v)
      ) labels in
      "{" ^ String.concat "," pairs ^ "}"

let to_prometheus_text () =
  update_uptime ();
  update_fd_gauges ();
  (* Snapshot (name, help, metric_type, value, labels) under the mutex so
     the render phase sees a consistent view even when concurrent fibers
     are still updating [metrics].  [m.value] is mutable so we copy it
     here rather than holding the lock for the full render. *)
  let snapshot =
    with_lock (fun () ->
      Hashtbl.fold
        (fun _ (m : metric) acc ->
          { name = m.name;
            help = m.help;
            metric_type = m.metric_type;
            value = m.value;
            labels = m.labels;
          } :: acc)
        metrics [])
  in
  let buf = Buffer.create 1024 in
  let by_name = Hashtbl.create 32 in
  List.iter (fun (m : metric) ->
    let existing = Hashtbl.find_opt by_name m.name |> Option.value ~default:[] in
    Hashtbl.replace by_name m.name (m :: existing)
  ) snapshot;
  (* Collect histogram parent names.  observe_histogram stores the
     cumulative sum under the original name and the observation count
     under "<name>_count".  We suppress standalone export of the
     _count companion and instead emit it inline as part of the
     summary stanza for the parent. *)
  let histogram_parents = Hashtbl.create 8 in
  Hashtbl.iter (fun name ms ->
    List.iter (fun (m : metric) ->
      if m.metric_type = Histogram then
        Hashtbl.replace histogram_parents name true
    ) ms
  ) by_name;
  let label_key labels =
    List.fold_left (fun acc (k, v) -> acc ^ k ^ v) "" labels
  in
  Hashtbl.iter (fun name ms ->
    let is_histogram_count =
      let suf = "_count" in
      let slen = String.length suf in
      String.length name > slen
      && String.sub name (String.length name - slen) slen = suf
      && Hashtbl.mem histogram_parents
           (String.sub name 0 (String.length name - slen))
    in
    if is_histogram_count then ()
    else
    match ms with
    | [] -> ()
    | m :: _ ->
      Buffer.add_string buf (Printf.sprintf "# HELP %s %s\n" name m.help);
      (match m.metric_type with
       | Histogram ->
         (* No bucket distribution is tracked, so emit as summary
            (sum + count) which is the closest valid Prometheus type. *)
         Buffer.add_string buf (Printf.sprintf "# TYPE %s summary\n" name);
         List.iter (fun (metric : metric) ->
           let ls = labels_to_string metric.labels in
           Buffer.add_string buf
             (Printf.sprintf "%s_sum%s %g\n" name ls metric.value);
           let count_key = name ^ "_count" ^ label_key metric.labels in
           let count_val =
             with_lock (fun () ->
               match Hashtbl.find_opt metrics count_key with
               | Some cm -> cm.value
               | None -> 0.0)
           in
           Buffer.add_string buf
             (Printf.sprintf "%s_count%s %g\n" name ls count_val)
         ) ms
       | _ ->
         Buffer.add_string buf
           (Printf.sprintf "# TYPE %s %s\n" name (type_to_string m.metric_type));
         List.iter (fun (metric : metric) ->
           Buffer.add_string buf (Printf.sprintf "%s%s %g\n"
             metric.name (labels_to_string metric.labels) metric.value)
         ) ms)
  ) by_name;
  Buffer.contents buf

(** {1 Convenience Functions} *)

let record_request () =
  inc_counter metric_mcp_requests ()

let record_task_completed () =
  inc_counter metric_tasks ~labels:[("status", "completed")] ()

let record_task_failed () =
  inc_counter metric_tasks ~labels:[("status", "failed")] ()

let record_error ?(error_type="unknown") () =
  inc_counter metric_errors ~labels:[("type", error_type)] ()

let set_active_agents count =
  set_gauge metric_active_agents (float_of_int count)

let set_pending_tasks count =
  set_gauge "masc_pending_tasks" (float_of_int count)

(** Reconcile active_agents gauge with existing agent files on disk.
    Call after Coord/server initialization to sync Prometheus state. *)
let reconcile_active_agents_gauge masc_dir =
  let agents_dir = Filename.concat masc_dir "agents" in
  if Sys.file_exists agents_dir && Sys.is_directory agents_dir then
    let files = Sys.readdir agents_dir in
    let count = Array.fold_left (fun acc f ->
      if Filename.check_suffix f ".json" then acc + 1 else acc
    ) 0 files in
    set_active_agents count

(** Initialize on module load *)
let () = init ()
