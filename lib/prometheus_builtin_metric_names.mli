(** Metric names used by Prometheus built-in registration chunks. *)

include module type of Prometheus_metric_names


(** #10097: per-(provider, tool) counter for keeper-bound runtime MCP
    omissions.  Paired with a once-per-fingerprint WARN log so logs
    carry structural facts and Prometheus carries frequency.

    RFC-0058 §2.4 / Phase 5.4: renamed from
    `masc_codex_cli_mcp_tool_omission_total` to keep provider identity
    out of the metric name; `provider` is now a label. *)
val metric_provider_mcp_tool_omission : string

(** #9520: total telemetry coverage gaps recorded. Labels:
    [source, producer, dashboard_surface, stale_reason]. This is the
    alertable pair to the durable
    [.masc/telemetry-coverage-gaps/YYYY-MM/DD.jsonl] store. *)
val metric_telemetry_coverage_gap : string

(** Total telemetry unified source discovery/read failures. Labels:
    [source] is {!Telemetry_unified.source_to_string}; [site] is a bounded
    read/discovery call-site vocabulary. *)
val metric_telemetry_unified_source_read_failures : string

(** Total tool-assignment telemetry decode/read failures. Labels:
    [site] is a bounded read/warm-up call-site vocabulary. *)
val metric_tool_assignment_telemetry_failures : string

(** Total {!Telemetry_observe} wrapper failures caught and returned as
    [Error]/default. Labels: [kind] is the wrapper call-site vocabulary.
    [Eio.Cancel.Cancelled] is re-raised and not counted. *)
val metric_telemetry_observe_failures : string

(** #10358 (c1): total times [lib/coord.ml]'s lifecycle hook caught
    [Stdlib.Effect.Unhandled] and dropped its Audit_log + Telemetry
    pair because dispatch happened outside an Eio scheduler. Labels:
    [event_family] (one of [agent_lifecycle] / [task_transition] /
    [accountability]) and [event_kind] (the variant). For
    [agent_lifecycle], [event_kind] is one of [join] / [rejoin] /
    [leave] (3 values). For both [task_transition] and
    [accountability], [event_kind] uses the 8
    [Masc_domain.task_action_to_string] values: [claim] / [start] /
    [done] / [cancel] / [release] / [submit_for_verification] /
    [approve] / [reject]. Cardinality bound: 19 series (3 + 8 + 8).
    Non-zero rate means a production path is firing the lifecycle
    outside an Eio fiber and the corresponding audit/telemetry rows
    are missing — the silent root cause behind the [#10358] 5-tag → 2-tag
    durable-ledger attrition. *)
val metric_coord_telemetry_drop : string

(** #10358 (c1): total times [lib/coord.ml]'s lifecycle hook caught
    [Stdlib.Effect.Unhandled] and dropped its Audit_log + Telemetry
    pair because dispatch happened outside an Eio scheduler. Labels:
    [event_family] (one of [agent_lifecycle] / [task_transition] /
    [accountability]) and [event_kind] (the variant). For
    [agent_lifecycle], [event_kind] is one of [join] / [rejoin] /
    [leave] (3 values). For both [task_transition] and
    [accountability], [event_kind] uses the 8
    [Masc_domain.task_action_to_string] values: [claim] / [start] /
    [done] / [cancel] / [release] / [submit_for_verification] /
    [approve] / [reject]. Cardinality bound: 19 series (3 + 8 + 8).
    Non-zero rate means a production path is firing the lifecycle
    outside an Eio fiber and the corresponding audit/telemetry rows
    are missing — the silent root cause behind the [#10358] 5-tag → 2-tag
    durable-ledger attrition. *)
val metric_coord_claim_post_provision_failures : string
(** Total best-effort claim post-provision hook failures. Labels: [site]
    and [agent_name]. *)

include module type of Prometheus_oas_metric_names

include module type of Prometheus_runtime_metric_names

(** {1 Core counters / gauges} *)

include module type of Prometheus_core_metric_names

val metric_open_fds : string
val metric_fd_warn_threshold : string
val metric_pool_idle_total : string
val metric_pool_inflight_total : string
val metric_pool_reuse_total : string
val metric_pool_evict_total : string
val metric_pool_evict_failure_total : string
val metric_pool_create_total : string

include module type of Prometheus_policy_metric_names

include module type of Prometheus_cascade_metric_names

(** Counter incremented once per breach event when [update_entry] drops
    cross [orphan_drop_threshold] inside [orphan_drop_window_sec] for a
    given [name]. Edge-triggered: subsequent drops in the same window
    bump only [metric_keeper_registry_update_dropped]. Labeled by [name]. *)

(** PR-J: number of times the per-turn OAS event-bus drain helper ran,
    labelled by call-site so operators can attribute drain pressure
    (e.g. background poller vs. unsubscribe vs. retry path).
    Labels: [site, outcome]. [outcome] is [drained] (events were
    pulled) or [empty] (subscriber returned no pending events). *)

(** Total keeper transitions to [Dead] phase after restart-budget exhaustion.
    Labeled by [keeper] and [reason]. Operators should alert on any rate >0:
    by construction Dead means the supervisor gave up and no further
    restart will be attempted. *)

(** Total keepers auto-resumed by the self-healing circuit breaker in
    [Keeper_supervisor.sweep_and_recover] after the per-keeper back-off
    timer elapsed.  Labeled by [keeper].  A positive rate indicates the
    system is self-healing from transient provider outages without operator
    intervention.  A sustained zero rate while [auto_resume_after_sec] is
    set in meta files indicates a sweep or meta-write regression. *)

(** Total keepers whose auto-resume was blocked in
    [Keeper_supervisor.sweep_and_recover] because the cascade health probe
    reported unhealthy (failure ratio >= threshold).  Labeled by [keeper]
    and [cascade].  A positive rate means the health gate is protecting
    the fleet from resuming into a still-failing cascade. *)

(** RFC-0020 Rule 2 evidence — incremented every time
    [run_smart_heartbeat_gate] overrides a [Skip_busy] / [Skip_idle]
    decision because the Event Layer queue
    ([Keeper_registry_event_queue.snapshot]) was non-empty. A zero
    rate against ongoing keeper activity means either the queue
    write path (PR-C1 [wakeup_keeper ?stimulus]) is not firing or
    the smart heartbeat is already returning [Emit] on its own —
    either way operators can distinguish. Labels: [keeper]. *)

(** Positive signal for the #12271 Skip_idle + Woken fix path. Increments
    each time [run_smart_heartbeat_gate] observes an external [wakeup_keeper]
    cut a Skip_idle backoff sleep short and the cycle was resumed
    ([cycle_continues_after_wake] -> [true]). Operator-meaningful pair with
    [masc_keeper_stale_termination_by_class_total] (class=idle_turn): a
    healthy fleet should show non-zero rates here proportional to inbound
    board signals, with the idle_turn kill rate trending toward zero. A
    zero rate after operator-visible signals suggests either the wakeup
    never reached the atomic, or a regression silently re-introduced
    MissedWakeup (KeeperHeartbeat.tla bug action).
    Labels: [keeper]. *)

(** Total stimuli consumed at turn entry, classified by [stimulus_class].
    Labels: [keeper], [class]
    (board_signal|bootstrap|alive_but_stuck_recovery|unsupported).
    Pairs with [masc_keeper_unsupported_stimulus_total] for unsupported-only
    drill-down with payload prefix. *)

(** Unsupported stimuli consumed at turn entry — the dequeued payload
    did not match any known stimulus class. Each increment represents a
    wake -> no_signal gap per #12684. Labels: [keeper]. *)

(** Total times a keeper restart attempt landed at
    [restart_count = max_restarts - 1], i.e. one attempt away from Dead.
    Soft pre-warning; labeled by [keeper]. *)

(** Total supervisor restart attempts for crashed keepers. Labels:
    [keeper]. *)

(** Total supervisor restart outcomes. Labels:
    [keeper, outcome]. Outcome is one of [started | meta_unavailable]. *)

(** #12801 Total Liveness Recovery Supervisor scan attempts to auto-recover
    Dead keepers. Increments each time a Dead keeper passes eligibility
    checks and a recovery is launched. Labels: [keeper]. *)

(** #12801 Total Liveness Recovery Supervisor outcomes. Labels:
    [keeper, outcome]. Outcome is one of:
    - [started]: keeper re-registered and fiber launched successfully
    - [not_running]: keeper re-registered but not in Running state after launch
    - [meta_missing]: no keeper meta file found — recovery skipped
    - [meta_read_failed]: meta read I/O error — recovery skipped
    - [meta_write_failed]: meta write to clear [paused] failed *)

(** PR-M (Leak 9): consecutive [oas_timeout_budget] cycle FAILED strikes.
    Labeled by [keeper] and [outcome]:
    - [outcome=warn]: strike below [oas_timeout_budget_strike_limit];
      cycle continues, supervisor not yet involved.
    - [outcome=promote]: strike at or above limit; [Keeper_fiber_crash]
      raised so [Keeper_supervisor.sweep_and_recover] respawns the
      fiber with a fresh context budget. Counter reset on any
      successful turn. *)

val metric_oas_bus_subscriber_stream_depth : string
val metric_oas_bus_publish_block_seconds : string
val metric_oas_bus_publish : string

val metric_oas_bus_capacity : string
(** Gauge: per-subscriber [Eio.Stream] capacity chosen at bus creation.
    Labels: [bus] names the MASC bus ([oas_runtime] | [masc_domain]),
    [policy] names the [Agent_sdk.Event_bus.backpressure_policy].
    Published once per bus at [Masc_event_bus_policy.create_bus] so
    operators can interpret [metric_oas_bus_subscriber_stream_depth]
    as a fraction of capacity. *)
val metric_runtime_ollama_probe_generate_skips : string

(** #9632: subprocess executions that exceeded their configured
    timeout. Labels: [program, timeout_sec]. *)
val metric_process_timeout : string

(** Background-task PID sidecar persistence failures. Labels:
    [site] = [write | read | read_parse | readdir | is_dir | unlink]. *)
val metric_bg_task_sidecar_failures : string

(** iter 30: unexpected (non-EAGAIN / EWOULDBLOCK / EINTR / EOF)
    errors raised by [Unix.read] inside [Bg_task.drain_fd_to_buf].
    Replaces the previous silent-EOF catch-all that hid genuine read
    errors (EBADF, EIO, ENOMEM, …) and lost any output between the
    error and process exit.  Labels are closed-vocabulary and
    cardinality-bounded:
    - [fd_kind] = [stdout | stderr] (call-site tagged).
    - [error_kind] = [unix_error | other] (typed match arm).
    Total cardinality: 4. *)
val metric_bg_task_drain_unexpected_errors : string

(** Build identity git probe failures. Labels:
    [site] = [commit_ts_git_capture | commit_ts_git_status | commit_ts_parse]. *)
val metric_build_identity_probe_failures : string

(** Build identity git probe failures. Labels:
    [site] = [commit_ts_git_capture | commit_ts_git_status | commit_ts_parse]. *)
val metric_distributed_lock_acquire_failed : string
(** #9645: distributed lock acquire retry-budget exhaustions.
    Labels: [key, attempts]. *)

(** #10130: boot-time sweep of save_file_atomic orphan temp files.
    Labels: [size_class = empty | with_data]. *)
val metric_fs_atomic_orphans_cleaned : string

include module type of Prometheus_identity_metric_names

(** {1 Transport metrics} *)

include module type of Prometheus_transport_metric_names

(** [masc_keeper_oas_run_timeout_total] counter incremented in the
    cascade FSM each time an [Agent.run] / [run_stream] returns
    [Llm_provider.Retry.Timeout]. The [source] label distinguishes the
    timeout origin so dashboards can attribute hangs to root cause:

    - [source="max_execution_time"] — agent_sdk's
      [with_optional_timeout] fired because the per-OAS-call ceiling
      ([max_execution_time_s], wired in PR #13923/#13933) was reached.
      This is the canonical signal for OAS call timeout enforcement.
    - [source="provider"] — transport-level timeout from the upstream
      provider (HTTP read deadline, gRPC deadline, etc.). The agent
      did not have [max_execution_time_s] set, or the timeout fired
      below the wrapper.

    Labels: cascade, provider, source. *)
(* Centralized metric constants for inline string replacement. *)

(** #13xxx: counter incremented every time the keeper dispatch layer
    denies a tool call because the tool is not in the keeper's allowlist.
    Surfaces preset drift (e.g. [board_core] group omitted from the
    keeper's [tool_groups]) and deny-list collisions as a Prometheus
    alert rather than requiring operators to grep
    [keepers/*.decisions.jsonl] after the fact.
    Labels:
    - [keeper] — keeper name
    - [tool]   — tool name attempted (bounded by tool registry, ~100)
    - [reason] — [not_in_candidate_set | denied_by_policy |
                  not_in_allow_set]
    Operator alert: [rate(masc_keeper_tool_not_allowed_total[5m]) > 0]
    on any [(keeper, tool)] pair means that keeper is looping without
    making progress — its BDI is requesting a tool that its preset
    does not permit. *)
val metric_after_turn_response_model_empty : string

val metric_after_turn_response_model_alias : string
val metric_pricing_catalog_miss : string
val metric_cost_emit_zero_source : string
val metric_cost_ledger_status : string
(* metric_keeper_meta_read_failures declared earlier in this interface (line 200) *)

(** RFC-0040: sender-side mention dedup decision counter.
    Labels: [outcome] with values
    [skipped|passed|no_target|bypassed]. *)
val metric_mention_dedup_decisions_total : string
