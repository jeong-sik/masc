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
include Prometheus_store

include Prometheus_metric_names

let backend_mutex_observers_installed = ref false

let install_backend_mutex_observers () =
  if not !backend_mutex_observers_installed
  then (
    Backend.FileSystem.set_mutex_observers
      ~acquire:(fun ~op ~seconds ->
        observe_histogram metric_backend_mutex_acquire_sec ~labels:[ "op", op ] seconds)
      ~held:(fun ~op ~seconds ->
        observe_histogram metric_backend_mutex_held_sec ~labels:[ "op", op ] seconds);
    backend_mutex_observers_installed := true)
;;

(* #10097: a provider cannot carry keeper-bound runtime MCP tools that
   need request-scoped auth headers.  Every time
   oas_worker_exec_transport strips such a tool, this counter
   increments with the [provider] and [tool] labels so dashboards can
   track WHICH provider strips WHICH tools and at WHAT rate.  Paired
   with a once-per-session WARN log ([fingerprint]-deduplicated) so
   the operator sees the structural fact exactly once while the
   counter carries the frequency signal.

   RFC-0058 §2.4 / Phase 5.4 big-bang rename: the old
   `masc_codex_cli_mcp_tool_omission_total` time series is RETIRED.
   Operators must point Grafana queries to the new
   `masc_provider_mcp_tool_omission_total{provider="codex_cli"}`
   series.  No dual-emit alias — the rename is intentional to keep
   provider identity out of the metric name. *)
let metric_provider_mcp_tool_omission = "masc_provider_mcp_tool_omission_total"

(* #9520: durable coverage-gap records must also have an alertable
   Prometheus surface.  The labels deliberately avoid raw paths and
   error strings; [source], [producer], [dashboard_surface], and
   [stale_reason] are bounded vocabularies owned by telemetry
   producers. *)
let metric_telemetry_coverage_gap = "masc_telemetry_coverage_gap_total"

(* Phase 0 telemetry fan-in: source discovery/read failures must not collapse
   into an indistinguishable empty dashboard. Labels are bounded by the
   Telemetry_unified.source enum and a small site vocabulary. *)
let metric_telemetry_unified_source_read_failures =
  "masc_telemetry_unified_source_read_failures_total"
;;

let metric_tool_assignment_telemetry_failures =
  "masc_tool_assignment_telemetry_failures_total"
;;

(* Phase 0 exception visibility for [Telemetry_observe]: every swallowed
   non-cancel exception logs and increments this bounded-by-callsite counter. *)
let metric_telemetry_observe_failures = "masc_telemetry_observe_failures_total"

(* #10358 (c1): observability for the silent [Effect.Unhandled] catch-all
   in [lib/coord.ml] [observe_agent_lifecycle] / [observe_task_transition_event] /
   [Keeper_accountability.record_task_transition].  Those three try/with
   sites swallow the exception that fires when the lifecycle hook is
   dispatched from a non-Eio context (test path, bootstrap, certain HTTP
   handlers).  Before this counter, the entire Audit_log + Telemetry pair
   silently disappeared, exactly matching the 5-tag → 2-tag attrition
   ledger pattern (only [tool_called] survives because it is wired on a
   different fiber-bearing path).  Labels: [event_family] (one of
   [agent_lifecycle] / [task_transition] / [accountability]) and
   [event_kind] (the lifecycle/transition variant). [event_kind] for
   [agent_lifecycle] is one of [join] / [rejoin] / [leave] (3 values).
   [event_kind] for both [task_transition] and [accountability] uses the
   8 [Masc_domain.task_action_to_string] values: [claim] / [start] /
   [done] / [cancel] / [release] / [submit_for_verification] / [approve]
   / [reject]. Both vocabularies are bounded so series cardinality is at
   most 19 (3 + 8 + 8). *)
let metric_coord_telemetry_drop = "masc_coord_telemetry_drop_total"

let metric_coord_claim_post_provision_failures =
  "masc_coord_claim_post_provision_failures_total"
;;

(* #10094: per-caller counter for [Masc_oas_bridge.run_safe]
   timeouts.  The [caller] string supplied at the run_safe entry
   point lets the operator see WHICH caller is timing out at
   WHICH configured budget without grepping warn-level log
   lines.  Paired with per-caller env-overridable defaults in
   [Env_config_oas_bridge] so 60s "fantasy" budgets in
   [auto_responder] / [dashboard_provider_runs] no longer
   silently masquerade as the same class of event as
   intentional 120s/180s budgets in autoresearch / deep_review. *)
include Prometheus_oas_metric_names

include Prometheus_cascade_metric_names

include Prometheus_runtime_metric_names

include Prometheus_transport_metric_names

(* Process-level FD gauges — used in init() and update_fd_gauges. *)
let metric_open_fds = "masc_process_open_fds"
let metric_fd_warn_threshold = "masc_process_fd_warn_threshold"
include Prometheus_core_metric_names

(* RFC-0107 Phase D.4 — piaf-backed connection pool gauges/counters.
   Names are owned by [Pool_metrics] (lib/server/pool_metrics.ml).
   Re-aliased here so [init] can register them in the central registry
   without reaching into the masc_http_client library. *)
let metric_pool_idle_total = Pool_metrics.metric_idle_total
let metric_pool_inflight_total = Pool_metrics.metric_inflight_total
let metric_pool_reuse_total = Pool_metrics.metric_reuse_total
let metric_pool_evict_total = Pool_metrics.metric_evict_total
let metric_pool_create_total = Pool_metrics.metric_create_total

include Prometheus_policy_metric_names

(* Increments each time [Keeper_turn_slot.force_release_holder_for] frees
   a slot held by a zombie fiber (typically because the fiber is stuck
   inside an LLM subprocess that did not honour cancellation). Without
   this path the slot stays held until process restart, starving the
   fleet behind the [reactive_turn_semaphore]. Labels: keeper, label
   ([turn] / [autonomous] / [reactive]). A positive rate means the
   force-release path is the only thing draining stuck slots, which is
   itself a signal that the upstream subprocess kill-on-cancel is
   incomplete and worth investigating. *)
(* P0-2 (2026-05-07): observability for orphan turn loops.
   [_dropped] increments every time [Keeper_registry.update_entry] is
   called against a missing key (caller raced with deregistration).
   [_orphan_threshold_breached] increments once per breach event when
   the per-keeper drop count crosses [orphan_drop_threshold] inside
   [orphan_drop_window_sec]. Together they let operators tell a
   harmless single-update race from a stuck orphan fiber emitting 30+
   drops per turn. See masc-mcp 2026-05-07 verifier-loop incident. *)
(* Self-healing circuit breaker: incremented each time [sweep_and_recover]
   auto-resumes a keeper after its back-off timer has elapsed.  A rate >0
   means the system is self-healing; a zero rate while keepers accumulate
   [auto_resume_after_sec] means the sweep is not firing or the meta write
   is failing. Labels: keeper. *)
(* Phase-3.5 health-gate block: incremented when the supervisor skips
   auto-resume because the keeper's cascade is unhealthy (failure ratio
   >= threshold).  Labels: keeper, cascade.  A positive rate means the
   health probe is actively protecting the fleet from resuming into a
   still-failing cascade. *)
(* Positive signal for the Skip_idle + Woken gate-promotion path added
   by #12271. Increments every time run_smart_heartbeat_gate observes
   that an external wakeup_keeper call cut a Skip_idle backoff sleep
   short and the cycle was resumed (KeeperHeartbeat.tla HeartbeatTick
   action). A zero rate after operator-visible board signals to a Live
   keeper means the fix path is not firing — either the wakeup never
   reached the atomic, or a regression silently re-introduced
   MissedWakeup. Pair with stale_termination_by_class for full
   positive/negative coverage. Labels: keeper. *)
(* #12801: Liveness Recovery Supervisor — auto-recover Dead keepers
   whose root cause has cleared.  [attempts] increments each time the
   scan selects a Dead keeper for recovery; [outcomes] breaks out the
   result by outcome label (started | not_running | meta_missing |
   meta_read_failed | meta_write_failed). Labels: keeper (for
   attempts) and keeper+outcome (for outcomes). *)
(* #12799: Passive loop detector — keeper emitting only read-only tool
   calls for N consecutive turns.  Labels: keeper. *)

(* Task-138: Minimum proactive cadence — observability gauges that pair
   with the [keeper_passive_loop_detector] streak counter so operators
   can see "alive but unproductive" keepers in Grafana before the
   detection latch fires.  Labels: keeper. *)
(* PR-M (Leak 9): consecutive [oas_timeout_budget] cycle FAILED strikes
   per keeper. Counter increments on each strike. At the limit, the
   heartbeat loop records [outcome=soft_backoff] unless
   [Keeper_failure_policy] sees separate keeper-liveness loss and returns
   a death-allowed decision. *)
let metric_oas_bus_subscriber_stream_depth = "masc_oas_bus_subscriber_stream_depth"
let metric_oas_bus_publish_block_seconds = "masc_oas_bus_publish_block_seconds_total"
let metric_oas_bus_publish = "masc_oas_bus_publish_total"
let metric_oas_bus_capacity = "masc_oas_bus_capacity"

(* Catch-all entries in [Cascade_event_bridge.native_event_to_json]
   for OAS payload variants that have not yet received an explicit
   arm in this consumer.  A non-zero rate per [kind] label means an
   upstream OAS pin bump shipped a new payload variant before the
   masc-mcp consumer was migrated; SSE subscribers receive only a
   kind-only placeholder payload until the explicit arm is added. *)
let metric_oas_bridge_unmigrated_payload_kind =
  "masc_oas_bridge_unmigrated_payload_kind_total"
;;

(* [Cascade_attempt_fsm.provider_label] receives an empty/blank string
   and falls back to the literal "unknown" so metric labels do not
   carry an empty value.  A non-zero rate here means an upstream
   call site is emitting metrics without a real provider name —
   the helper paints over the symptom; the counter surfaces it so
   the source can be found and fixed. *)
let metric_cascade_attempt_empty_provider_label =
  "masc_cascade_attempt_empty_provider_label_total"
;;

(* Per-tool-result compaction events emitted by
   [Keeper_context_core.sanitize_checkpoint_message] when a tool
   result exceeds the per-message count cap, the aggregate byte
   budget, or its own single-result byte cap.  Labels are
   closed-vocabulary so cardinality is bounded:
     action  = stubbed | truncated
     reason  = over_count | over_aggregate_bytes | over_single_byte
   The [stubbed] action replaces the content entirely with a marker
   string; [truncated] caps the content and appends a marker. *)
let metric_keeper_context_tool_result_compacted =
  "masc_keeper_context_tool_result_compacted_total"
;;
let metric_runtime_ollama_probe_generate_skips =
  "masc_runtime_ollama_probe_generate_skips_total"
;;

let metric_process_timeout = "masc_process_timeout_total"
let metric_bg_task_sidecar_failures = "masc_bg_task_sidecar_failures_total"
(* iter 30: typed split for [Bg_task.drain_fd_to_buf] silent error
   swallow.  Previously every non-EAGAIN/EWOULDBLOCK/EINTR exception
   was collapsed into a permissive EOF, hiding real read errors
   (EBADF, EIO, ENOMEM, …).  Labels are closed-vocabulary:
   [fd_kind = stdout | stderr] × [error_kind = unix_error | other],
   cardinality 4. *)
let metric_bg_task_drain_unexpected_errors =
  "masc_bg_task_drain_unexpected_errors_total"
let metric_build_identity_probe_failures = "masc_build_identity_probe_failures_total"
let metric_distributed_lock_acquire_failed = "masc_distributed_lock_acquire_failed_total"

(* #10130: boot-time sweep of [save_file_atomic] orphan temp
   files.  Labels: [size_class = empty | with_data].  The
   [with_data] rate is the interesting operator signal — each
   non-zero orphan represents a silent atomic-save failure
   (SIGKILL / ENFILE mid-write) that dropped the payload. *)
let metric_fs_atomic_orphans_cleaned = "masc_fs_atomic_orphans_cleaned_total"

include Prometheus_identity_metric_names

(* Centralized from keeper_stale_watchdog.ml.  Originally each metric was
   an inline string literal passed to inc_counter / register_counter.
   Constants make grep/audit trivial and prevent typo-induced metric
   proliferation (a single-character typo creates a new invisible metric). *)

(* Centralized metric constants for inline string replacement.
   keeper_hooks_oas.ml, keeper_guards.ml, keeper_execution_receipt.ml,
   keeper_shell_bash.ml, keeper_shell_docker.ml,
   keeper_heartbeat_snapshot.ml, keeper_stay_silent_loop_detector.ml,
   keeper_unified_metrics.ml. *)
(* #13xxx: keeper dispatch layer denied a tool call because the
   tool is not in the keeper's allowlist (preset drift, deny-list,
   or unknown tool name).  Distinct from [Keeper_metrics.metric_keeper_tool_use_failure]
   (post-execution hook failure) and
   [Keeper_metrics.metric_keeper_turn_gate_rejected_terminal] (pre_tool_use guard
   hard-reject).  Labels:
   - [keeper] — keeper name (fleet-bounded)
   - [tool]   — tool name attempted (registry-bounded, ~100 tools)
   - [reason] — vocabulary:
       "not_in_candidate_set" (unknown / not available to this preset)
       "denied_by_policy"     (explicit deny-list entry)
       "not_in_allow_set"     (tool exists but preset omits it)
   Cardinality: ~16 keepers × ~100 tools × 3 reasons = ~4800 series. *)
let metric_after_turn_response_model_empty = "masc_after_turn_response_model_empty_total"
let metric_after_turn_response_model_alias = "masc_after_turn_response_model_alias_total"
let metric_pricing_catalog_miss = "masc_pricing_catalog_miss_total"
let metric_cost_emit_zero_source = "masc_cost_emit_zero_source_total"
let metric_cost_ledger_status = "masc_cost_ledger_status_total"
(* metric_keeper_meta_read_failures defined earlier at line 473 (single
   source of truth). Re-binding here would silently shadow without
   changing behavior because the strings are identical, but it makes
   the constant look like it has two declaration sites. *)

(* RFC-0040: sender-side mention dedup decision counter.  Labels:
   [outcome] in [skipped|passed|no_target|bypassed].  Wired from
   [lib/coord.ml] via [Coord_hooks.mention_dedup_decision_fn]. *)
let metric_mention_dedup_decisions_total = "masc_mention_dedup_decisions_total"

(** {1 Built-in Metrics} *)

let init () =
  let add name help metric_kind =
    match metric_kind with
    | `Counter -> register_counter ~name ~help ()
    | `Gauge -> register_gauge ~name ~help ()
    | `Histogram -> register_histogram ~name ~help ()
  in
  Prometheus_builtin_metrics.register
    ~add
    ~register_histogram
    ~register_gauge
    ~inc_counter
    ();
  install_backend_mutex_observers ()
;;

let start_time = Time_compat.now ()
let update_uptime () = set_gauge metric_uptime_seconds (Time_compat.now () -. start_time)

let fd_warn_threshold = Prometheus_process.fd_warn_threshold
let () = set_gauge metric_fd_warn_threshold (float_of_int fd_warn_threshold)

(** Returns 0 on non-Unix hosts where [/dev/fd] is unavailable. *)
let approximate_open_fd_count = Prometheus_process.approximate_open_fd_count

let update_fd_gauges () =
  Prometheus_process.update_fd_gauges
    ~set_gauge:(fun name value -> set_gauge name value)
    ~metric_open_fds
;;

let update_fd_accountant_gauges () =
  let snapshot = Fd_accountant.fd_snapshot () in
  set_gauge metric_fd_open (float_of_int snapshot.fd_open);
  set_gauge metric_fd_limit (float_of_int snapshot.fd_limit);
  set_gauge
    metric_fd_pressure_active
    (if snapshot.pressure_active then 1.0 else 0.0);
  List.iter
    (fun (kind, in_flight) ->
      set_gauge
        metric_fd_in_flight
        ~labels:[ "kind", Fd_accountant.kind_to_string kind ]
        (float_of_int in_flight))
    snapshot.per_kind
;;

let set_tool_schema_stats ~count ~approx_tokens =
  set_gauge metric_mcp_tool_schema_count (float_of_int count);
  set_gauge metric_mcp_tool_schema_tokens_approx (float_of_int approx_tokens)
;;

let type_to_string = Prometheus_render.type_to_string
let labels_to_string = Prometheus_render.labels_to_string

(* Track host labels seen in previous scrapes so we can zero out gauges
   for hosts that disappeared from the pool. Without this, an evicted
   host's last non-zero idle value would persist in the registry forever
   and the metrics table would grow unboundedly with every unique host
   seen. Set is module-local: only [update_pool_metrics_gauges] reads
   or writes it, and [to_prometheus_text]'s mutex serialises calls. *)
let pool_idle_seen_hosts : (string, unit) Hashtbl.t = Hashtbl.create 16

let update_pool_metrics_gauges () =
  match Pool_metrics.current_snapshot () with
  | None -> ()
  | Some stats ->
    set_gauge metric_pool_inflight_total (float_of_int stats.total_inflight);
    let current_hosts = List.map fst stats.idle_per_host in
    let current_set = List.fold_left (fun acc h -> Hashtbl.replace acc h (); acc)
                        (Hashtbl.create (List.length current_hosts)) current_hosts in
    (* Zero out gauges for hosts that disappeared since the last scrape. *)
    Hashtbl.iter
      (fun host () ->
        if not (Hashtbl.mem current_set host)
        then set_gauge metric_pool_idle_total ~labels:[ "host", host ] 0.0)
      pool_idle_seen_hosts;
    (* Write current values + remember them for the next scrape. *)
    List.iter
      (fun (host, idle) ->
        set_gauge
          metric_pool_idle_total
          ~labels:[ "host", host ]
          (float_of_int idle);
        Hashtbl.replace pool_idle_seen_hosts host ())
      stats.idle_per_host;
    (* Drop evicted hosts from the seen-set so we stop tracking them. *)
    Hashtbl.filter_map_inplace
      (fun host () -> if Hashtbl.mem current_set host then Some () else None)
      pool_idle_seen_hosts;
    set_gauge metric_pool_idle_total (float_of_int stats.total_idle);
    set_gauge metric_pool_reuse_total (float_of_int stats.reuse_count_total);
    set_gauge metric_pool_evict_total (float_of_int stats.evict_count_total);
    set_gauge metric_pool_create_total (float_of_int stats.create_count_total)
;;

let to_prometheus_text () =
  update_uptime ();
  update_fd_gauges ();
  update_fd_accountant_gauges ();
  update_pool_metrics_gauges ();
  Prometheus_store.snapshot () |> Prometheus_render.render_snapshot
;;

(** {1 Convenience Functions} *)
let record_request () = inc_counter metric_mcp_requests ()

let record_task_completed () =
  inc_counter metric_tasks ~labels:[ "status", "completed" ] ()
;;
let record_task_failed () = inc_counter metric_tasks ~labels:[ "status", "failed" ] ()

let record_error ?(error_type = "unknown") () =
  inc_counter metric_errors ~labels:[ "type", error_type ] ()
;;
let set_active_agents count = set_gauge metric_active_agents (float_of_int count)
let set_pending_tasks count = set_gauge "masc_pending_tasks" (float_of_int count)
(** Reconcile active_agents gauge with existing agent files on disk.
    Call after Coord/server initialization to sync Prometheus state. *)
let reconcile_active_agents_gauge masc_dir =
  let agents_dir = Filename.concat masc_dir "agents" in
  if Sys.file_exists agents_dir && Sys.is_directory agents_dir
  then (
    let files = Sys.readdir agents_dir in
    let count =
      Array.fold_left
        (fun acc f -> if Filename.check_suffix f ".json" then acc + 1 else acc)
        0
        files
    in
    set_active_agents count)
;;

(** Initialize on module load *)
let () = init ()
