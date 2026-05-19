(** Built-in metric registration chunk. *)

open Prometheus_builtin_metric_names

type metric_kind = [ `Counter | `Gauge | `Histogram ]

type register_histogram =
  name:string -> help:string -> ?labels:(string * string) list -> unit -> unit

type inc_counter =
  string -> ?labels:(string * string) list -> ?delta:float -> unit -> unit

let register
      ~(add : string -> string -> metric_kind -> unit)
      ~(register_histogram : register_histogram)
      ~(inc_counter : inc_counter)
      ()
  =
  add
    metric_fd_open
    "Best-effort FD accountant observation of process-wide open file descriptors."
    `Gauge;
  add
    metric_fd_limit
    "Best-effort FD accountant observation of the process RLIMIT_NOFILE soft cap."
    `Gauge;
  add
    metric_fd_in_flight
    "Current in-flight FD-accounted operations by kind. Labels: kind."
    `Gauge;
  add
    metric_fd_pressure_active
    "Whether the shared keeper FD-pressure breaker is active (1 active, 0 inactive)."
    `Gauge;
  (* RFC-0107 Phase D.4 — piaf connection pool metrics.  Snapshot
     pushed by [update_pool_metrics_gauges] inside [to_prometheus_text]. *)
  add
    metric_pool_idle_total
    "Idle (reusable) connections held by the piaf-backed HTTP pool. \
     With label [host=\"scheme://host:port\"] this is the per-endpoint \
     count; the unlabelled time series is the across-host total."
    `Gauge;
  add
    metric_pool_inflight_total
    "Currently in-flight HTTP requests checked out of the piaf-backed pool."
    `Gauge;
  add
    metric_pool_reuse_total
    "Cumulative count of pooled connection reuses (keep-alive hits)."
    `Counter;
  add
    metric_pool_evict_total
    "Cumulative count of pooled connections evicted by idle-TTL or LRU cap."
    `Counter;
  add
    metric_pool_evict_failure_total
    "Cumulative count of exceptions caught by the eviction fiber while \
     sweeping idle entries. Previously swallowed by [with _ -> ()]; \
     a non-zero value indicates the periodic TTL cleanup is silently \
     failing and the pool may leak idle connections."
    `Counter;
  add
    metric_pool_create_total
    "Cumulative count of fresh piaf [Client.t] connections created on pool miss."
    `Counter;
  (* Per-keeper turn outcome + token counters.  Labels are populated
     dynamically via inc_counter; no upfront registration needed.
     Covers issues #7495 (cost/token attribution) and #7519 (SLO). *)
  add
    Keeper_metrics.metric_keeper_turns
    "Total keeper turns by outcome (labels: keeper_name, \
     outcome=success|failure|budget_exhausted|mutation_boundary)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_scheduled
    "Total keeper turns accepted for dispatch by keeper_name."
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_completed
    "Total keeper turns that completed and emitted a metrics snapshot by keeper_name."
    `Counter;
  add
    Keeper_metrics.metric_keeper_input_tokens
    "Cumulative input tokens per keeper turn (labels: keeper_name, model)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_output_tokens
    "Cumulative output tokens per keeper turn (labels: keeper_name, model)"
    `Counter;
  (* Anthropic / Bedrock prompt caching observability (#7469 Step 1).
     OAS already receives [cache_creation_input_tokens] and
     [cache_read_input_tokens] in every [api_usage]; these counters
     expose them to Prometheus so cache hit-rate and write cost are
     attributable per keeper + model. Populated dynamically via
     [inc_counter]; tools that never emit cache data (e.g. non-Anthropic
     providers) simply leave these at 0. Names are exported as module
     constants below so registration and call-sites cannot drift. *)
  add
    Keeper_metrics.metric_keeper_cache_creation_tokens
    "Cumulative prompt-cache creation tokens per keeper turn (labels: keeper_name, model)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_cache_read_tokens
    "Cumulative prompt-cache read tokens per keeper turn (labels: keeper_name, model)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_usage_anomalies
    "Keeper turns whose reported usage was marked untrusted (labels: keeper_name, model, \
     reason)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_total_cost_usd
    "Accumulated trusted USD cost per keeper (labels: keeper_name)"
    `Gauge;
  add
    Keeper_metrics.metric_keeper_idle_seconds
    "Current keeper world-observation idle seconds by keeper_name. Updated from \
     observation.idle_seconds during keeper metrics emission so long idle gaps are \
     visible as Prometheus data, not only in message text."
    `Gauge;
  add
    Keeper_metrics.metric_keeper_contract_violations
    "Keeper turns rejected for required-tool-contract violations (labels: keeper_name, \
     kind={passive|text_only}). #10530."
    `Counter;
  add
    Keeper_metrics.metric_keeper_alive_but_stuck
    "Keepers detected as alive-but-stuck: non-Dead, non-paused, keepalive-running, but \
     proactive_rt.last_ts has been frozen while autonomous turns kept advancing. Labels: \
     keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_alive_but_stuck_seconds
    "Current alive-but-stuck elapsed seconds by keeper_name. Set to 0 when the keeper is \
     not currently detected as alive-but-stuck."
    `Gauge;
  add
    Keeper_metrics.metric_keeper_alive_but_stuck_threshold_seconds
    "Current alive-but-stuck detector threshold seconds by keeper_name."
    `Gauge;
  add
    Keeper_metrics.metric_keeper_alive_but_stuck_recovery
    "Bounded recovery wakeups queued by alive_but_stuck_scan. Labels: keeper, outcome."
    `Counter;
  (* Tool schema budget gauges — set once at boot via
     [set_tool_schema_stats]. Covers #7483 Step 1. *)
  add metric_mcp_tool_schema_count "Number of tool schemas exposed to MCP clients" `Gauge;
  add
    metric_mcp_tool_schema_tokens_approx
    "Approximate token count of all tool schemas combined (chars/4)"
    `Gauge;
  (* OAS Event_bus backpressure observability (see oas_bus_instrument.ml).
     Label series are populated dynamically per subscriber_purpose. *)
  add
    metric_oas_bus_subscriber_stream_depth
    "Estimated OAS Event_bus per-subscriber stream depth, labeled by subscriber_purpose. \
     Indirect measure: publishes_matching_filter - events_drained, tracked MASC-side for \
     subscriptions created via Agent_sdk_metrics_bridge. OAS uses bounded Eio.Stream \
     (default 256); values approaching this cap indicate impending publish blocking."
    `Gauge;
  add
    metric_oas_bus_publish_block_seconds
    "Cumulative seconds spent inside Agent_sdk.Event_bus.publish when routed through \
     Agent_sdk_metrics_bridge.publish. A sustained ramp indicates a subscriber drain \
     loop has fallen behind and publishers are blocking on Eio.Stream.add."
    `Counter;
  add
    metric_oas_bus_publish
    "Total Agent_sdk.Event_bus.publish calls routed through \
     Agent_sdk_metrics_bridge.publish."
    `Counter;
  add
    metric_runtime_ollama_probe_generate_skips
    "Total Ollama runtime probes that intentionally skipped /api/generate. Labeled by \
     reason=status_only|model_unloaded|ps_error|no_effective_model|policy_skip."
    `Counter;
  add
    metric_process_timeout
    "Total subprocess executions that exceeded their configured timeout. Labeled by \
     program and timeout_bucket (Timeout_bucket.to_label: lt_1s | ge_1s_lt_15s | \
     ge_15s_lt_60s | ge_60s_lt_300s | ge_300s)."
    `Counter;
  add
    metric_bg_task_sidecar_failures
    "Total background-task PID sidecar persistence failures. Labeled by \
     site=write|read|read_parse|readdir|is_dir|unlink."
    `Counter;
  Bg_task.set_sidecar_failure_observer (fun ~site _exn ->
    inc_counter metric_bg_task_sidecar_failures ~labels:[ "site", site ] ());
  add
    metric_bg_task_drain_unexpected_errors
    "Total unexpected (non-EAGAIN/EWOULDBLOCK/EINTR/EOF) errors raised by \
     Unix.read inside Bg_task.drain_fd_to_buf. Labeled by \
     fd_kind=stdout|stderr and error_kind=unix_error|other. A non-zero \
     rate indicates the previous silent-EOF fallback would have hidden a \
     real read error and lost output between the error and process exit."
    `Counter;
  Bg_task.set_drain_failure_observer (fun ~fd_kind ~err_kind ->
    inc_counter metric_bg_task_drain_unexpected_errors
      ~labels:[ "fd_kind", fd_kind; "error_kind", err_kind ] ());
  add
    metric_build_identity_probe_failures
    "Total build identity git probe failures. Labeled by \
     site=commit_ts_git_capture|commit_ts_git_status|commit_ts_parse."
    `Counter;
  add
    metric_distributed_lock_acquire_failed
    "Total distributed lock acquire exhaustions. Labeled by key and attempts. A non-zero \
     rate indicates lock contention exhausted the retry budget."
    `Counter;
  (* #10130: boot-time sweep of save_file_atomic orphans. *)
  add
    metric_fs_atomic_orphans_cleaned
    "Total save_file_atomic orphan temp files cleaned at boot (labels: \
     size_class=empty|with_data).  [with_data] rate > 0 indicates silent atomic-save \
     failures (SIGKILL / ENFILE) that dropped payloads; moved to \
     [<base_path>/.recovered/]."
    `Counter;
  (* #9786: auth layer rejects a request whose bearer token resolves
     to a credential owner different from the requested agent. *)
  add
    metric_auth_bearer_token_mismatch
    "Total Auth rejects where bearer token owner does not match the requested agent_name \
     (labels: expected_agent, actual_agent). Rate advancing after a server restart \
     indicates shared credential state (connection pool / process fork) across agent \
     identities."
    `Counter;
  add
    metric_auth_strict_unknown_tool_denials
    "Total strict Auth rejects for unknown external tools (labels: agent_name, \
     tool_class=empty|external). This catches fleet-wide tool dispatch regressions \
     without using raw tool names as metric labels."
    `Counter;
  add
    metric_auth_credential_token_duplicate
    "Total boot-time credential token duplicate groups detected (labels: \
     token_hash_prefix). Any non-zero value means credential tokens must be rotated."
    `Counter;
  add
    metric_auth_credential_token_rotated
    "Total credentials automatically rotated out of a shared bearer-token group (labels: \
     token_hash_prefix, scope). Any positive value means boot-time prevention repaired \
     ambiguous credential state."
    `Counter;
  add
    metric_config_credential_archived_starvation
    "Total bare-form keeper credential files archived because they are dead after PR-3b1 \
     starvation. Labels: keeper_name."
    `Counter;
  add
    metric_auth_bare_alias
    "Steady-state count of bare-form keeper alias files per classifier state. \
     Labels: state=alive|dead|no_bare. Non-zero state=dead is the ping-pong \
     regression canary for PR #15112 γ guard; alert on it."
    `Gauge;
  add
    metric_auth_archive_epochs
    "Current number of .archive/<epoch>/ subdirectories after the retention \
     sweep. Tracks disk inventory growth of archived credentials."
    `Gauge;
  add
    metric_auth_archive_pruned_total
    "Total .archive/<epoch>/ subdirectories removed by the boot-time retention \
     sweep. Increments by the per-boot prune count."
    `Counter;
  add
    metric_auth_bare_alias_outcome_total
    "Total dispatch outcomes of Auth.archive_bare_for_canonical. Labels: \
     outcome=alive_skip|dead_archive|absent. The dead_archive rate surfaces \
     per-call archive frequency that the snapshot gauge cannot show; \
     alive_skip counts confirm the γ guard is preserving PR-#10440 aliases."
    `Counter;
  add
    metric_auth_bare_alias_audit_ticks_total
    "Heartbeat counter for the periodic bare_alias_audit fiber. Increments on \
     every successful tick. rate([5m]) < 0.01 indicates fiber stall, \
     distinguishable from scrape-stall (which would absent all auth metrics)."
    `Counter;
  add
    metric_telemetry_coverage_gap
    "Total telemetry coverage gaps recorded before append to the durable coverage-gap \
     store. Labels: source, producer, dashboard_surface, stale_reason. Any positive rate \
     means a telemetry lane is missing, stale, or failed to append and dashboards should \
     mark the source coverage_gap."
    `Counter;
  add
    metric_telemetry_unified_source_read_failures
    "Total telemetry unified source discovery/read failures. Labels: \
     source=keeper_metric|agent_event|tool_call_io|trajectory_tool_call|tool_usage|oas_event|execution_receipt|goal_event|tool_metric \
     and site=<bounded read/discovery call-site>. Any positive rate means the dashboard \
     fan-in returned partial data instead of a true empty source."
    `Counter;
  add
    metric_tool_assignment_telemetry_failures
    "Total tool assignment telemetry decode/read failures. Labels: \
     site=read_recent_decode|read_recent_exception|warm_up_decode|warm_up_exception. Any \
     positive rate means tool assignment lifecycle rows were dropped from the \
     reconstructed read model."
    `Counter;
  add
    metric_telemetry_observe_failures
    "Total Telemetry_observe wrapper failures that were caught and returned as \
     Error/default instead of silently disappearing. Labels: kind=<bounded call-site \
     vocabulary>. Eio.Cancel.Cancelled is re-raised and not counted."
    `Counter;
  add
    metric_coord_telemetry_drop
    "Total times a Coord lifecycle/transition hook dropped its Audit_log + Telemetry \
     emit because the dispatch happened outside an Eio scheduler. Labels: event_family \
     (one of agent_lifecycle | task_transition | accountability) and event_kind (the \
     variant). event_kind values: agent_lifecycle uses join | rejoin | leave (3 values); \
     task_transition and accountability both use the 8 task_action variants claim | \
     start | done | cancel | release | submit_for_verification | approve | reject. \
     Cardinality bound: 19 series (3 + 8 + 8). Non-zero rate means a production path is \
     firing the lifecycle outside an Eio context; before this counter the drop was \
     silent (#10358 attrition root cause)."
    `Counter;
  add
    metric_coord_claim_post_provision_failures
    "Total best-effort claim post-provision hook failures. Labels: site (claim_task | \
     claim_next) and agent_name. Task IDs are logged but not labeled to keep series \
     cardinality bounded."
    `Counter;
  add
    metric_auth_credential_ambiguous_lookup
    "Total runtime credential lookups where N>=2 credentials share the same token hash. \
     Labels: first_match (the agent_name that List.find routed to). Distinguishes \
     \"audit warning, no traffic\" from \"duplicate token actively serving the wrong \
     agent\"."
    `Counter;
  add
    metric_silent_auth_token_resolve_error
    "Total times mcp_server_eio_execute fell back to the requester-supplied agent_name \
     because Auth.resolve_agent_from_token returned an Error. Labels: error_kind \
     (token_mismatch | token_expired | other), agent (the alias the request kept). \
     Non-zero rate means token-based identity rewrite is silently disabled in \
     production."
    `Counter;
  add
    metric_silent_dashboard_actor_fallback
    "Total times Server_auth.dashboard_actor_for_request resolved no agent from the \
     bearer token (Ok None / Error _) and fell back to request_actor_hint. Labels: \
     outcome (none | error), err_kind on error paths. `Counter exposes the path that \
     masks identity drift in the HTTP transport."
    `Counter;
  add
    metric_auth_strict_would_reject
    "Phase A F2 (2026-04-27): every silent_auth_token_resolve_error fall-through in \
     mcp_server_eio_execute also increments this counter so operators can measure how \
     many of those would-be-rejections happen under each MASC_AUTH_STRICT mode before \
     Phase B PR-2 promotes Strict to a typed reject. Labels: mode (off | dry_run | \
     strict), error_kind, agent."
    `Counter;
  add
    metric_empty_tool_universe_observed
    "Phase A F3 (2026-04-28): increments every time the keeper turn enters the \
     [Keeper_tool_surface_empty] blocker branch in keeper_agent_run (i.e. \
     tool_gate_requested && all_allowed = []). Pre-fix the blocker fired silently with \
     no operator-visible counter; this surfaces the volume so Phase B PR-4 can promote \
     it to a typed terminal state with LLM-visible feedback. Labels: keeper_name, \
     turn_lane (text_only | tool_optional | tool_required | retry | tool_disabled), \
     fallback_used (true | false)."
    `Counter;
  add
    metric_coord_join_normalize_outcome
    "Total Coord.join identity normalizations by Keeper_identity.normalize_all_names \
     (RFC P3-a). Labels: outcome (ok | empty_input | persona_not_found | \
     credential_missing | name_ambiguous | ephemeral_suffix_rejected). Non-ok outcomes \
     reject masc_join at the fail-closed identity gate; pair with \
     masc_silent_auth_token_resolve_error_total for auth/name drift diagnosis."
    `Counter;
  add
    metric_config_unknown_keys_ignored
    "Total unknown config keys ignored after warning. Labels: file_path. The counter \
     increments by the number of unknown keys in a newly-observed keeper TOML warning \
     set."
    `Counter;
  add
    metric_governance_judge_unparseable
    "Total governance/operator judge responses that remained unparseable after \
     deterministic JSON recovery. Labels: judge."
    `Counter;
  add
    metric_governance_lenient_json_fallback_hit
    "Total Lenient_json fallback hits for governance/operator judge output. Labels: \
     judge."
    `Counter;
  (* Transport metrics — registered here so transport_metrics.ml can use
     module constants instead of string literals. *)
  add metric_sse_sessions "Active SSE sessions by kind" `Gauge;
  register_histogram
    ~name:metric_sse_broadcast_duration
    ~help:"Time to fan-out a broadcast to all SSE clients"
    ();
  add metric_sse_broadcast_events "Total SSE broadcast events emitted" `Counter;
  add
    metric_sse_broadcast_failures
    "SSE broadcast deliveries that failed (stream full or enqueue exception). Labelled \
     by target so the failure rate can be compared against \
     masc_sse_broadcast_events_total per target."
    `Counter;
  add
    metric_sse_external_subscriber_callback_failures
    "External SSE subscriber callback exceptions (e.g. gRPC bridge stream errors).  A \
     non-zero rate indicates that a downstream consumer is failing to accept events even \
     though the SSE fanout considers the broadcast successful."
    `Counter;
  add
    metric_oas_sse_relay_drop_marker_failures
    "OAS relay drop-marker broadcasts that themselves failed to emit. The drop marker is \
     the operator-visible signal that an OAS event was dropped after exhausting retries; \
     if the drop marker also fails to broadcast, operators are blind to the drop \
     entirely. Distinct from masc_sse_broadcast_failures_total because the drop marker \
     is the recovery path's last resort, not a normal broadcast."
    `Counter;
  add metric_sse_stream_queue_depth "Per-session SSE event stream queue depth" `Gauge;
  add
    metric_sse_queue_depth_avg
    "Average SSE event queue depth across live sessions"
    `Gauge;
  add
    metric_sse_queue_depth_max
    "Maximum SSE event queue depth across live sessions"
    `Gauge;
  add
    metric_sse_external_subscribers
    "Active non-SSE subscribers bridged from the SSE fanout path"
    `Gauge;
  add
    metric_sse_client_evictions
    "SSE clients evicted from the registry because [max_clients] was reached and a new \
     client connected.  Pairs with the [Evicting oldest client] log line so operators \
     can see eviction storms in metrics without scraping logs.  A non-zero rate is the \
     early warning that broadcast fan-out is keeping mailboxes full faster than slow \
     consumers can drain."
    `Counter;
  register_histogram
    ~name:metric_coord_broadcast_duration
    ~help:
      "Coord_broadcast.broadcast latency (next_seq + agent.json read + msg.json write + \
       activity emit + on_broadcast_mention). Pairs with \
       masc_sse_broadcast_duration_seconds. Labels: msg_type."
    ();
  add
    metric_file_lock_retries
    "F_TLOCK retries before [acquire_flock_retry*] returned. Pairs with \
     masc_file_lock_acquire_seconds. Labels: caller."
    `Counter;
;;
