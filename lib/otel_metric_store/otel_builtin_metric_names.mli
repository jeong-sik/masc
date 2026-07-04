(** Metric names used by Otel_metric_store built-in registration chunks. *)

include module type of Otel_metric_names


(** #10097: per-(provider, tool) counter for keeper-bound runtime MCP
    omissions.  Paired with a once-per-fingerprint WARN log so logs
    carry structural facts and Otel_metric_store carries frequency.

    RFC-0058 §2.4 / Phase 5.4: renamed from
    `masc_codex_cli_mcp_tool_omission_total` to keep provider identity
    out of the metric name; `provider` is now a label. *)

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

(** #10358 (c1): total times [lib/workspace.ml]'s lifecycle hook caught
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
val metric_workspace_telemetry_drop : string

include module type of Otel_oas_metric_names

include module type of Otel_runtime_metric_names

(** {1 Core counters / gauges} *)

include module type of Otel_core_metric_names
val metric_pool_idle_total : string
val metric_pool_inflight_total : string
val metric_pool_reuse_total : string
val metric_pool_evict_total : string
val metric_pool_evict_failure_total : string
val metric_pool_create_total : string

include module type of Otel_policy_metric_names

(** Total keepers auto-resumed by the self-healing circuit breaker in
    [Keeper_supervisor.sweep_and_recover] after the per-keeper back-off
    timer elapsed.  Labeled by [keeper].  A positive rate indicates the
    system is self-healing from transient provider outages without operator
    intervention.  A sustained zero rate while [auto_resume_after_sec] is
    set in meta files indicates a sweep or meta-write regression. *)

(** Total keepers whose auto-resume was blocked in
    [Keeper_supervisor.sweep_and_recover] because the runtime health probe
    reported unhealthy (failure ratio >= threshold).  Labeled by [keeper]
    and [runtime].  A positive rate means the health gate is protecting
    the fleet from resuming into a still-failing runtime. *)

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
    (board_signal|bootstrap|no_progress_recovery|unsupported).
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

(** PR-M (Leak 9): consecutive [provider_timeout] cycle FAILED strikes.
    Labeled by [keeper] and [outcome]:
    - [outcome=warn]: strike below [provider_timeout_strike_limit];
      cycle continues, supervisor not yet involved.
    - [outcome=promote]: strike at or above limit; [Keeper_fiber_crash]
      raised so [Keeper_supervisor.sweep_and_recover] respawns the
      fiber with a fresh context budget. Counter reset on any
      successful turn. *)


val metric_oas_bus_capacity : string
(** Gauge: per-subscriber [Eio.Stream] capacity chosen at bus creation.
    Labels: [bus] names the MASC bus ([oas_runtime] | [masc_domain]),
    [policy] names the [Agent_sdk.Event_bus.backpressure_policy].
    Published once per bus at [Masc_event_bus_policy.create_bus] so
    operators can interpret [masc_event_bus_subscriber_depth]
    as a fraction of capacity. *)

val metric_oas_bridge_unmigrated_payload_kind : string
val metric_keeper_context_tool_result_compacted : string

(** #9632: subprocess executions that exceeded their configured
    timeout. Labels: [program, timeout_sec]. *)
val metric_process_timeout : string

(** Background-task PID sidecar persistence failures. Labels:
    [site] = [write | read | read_parse | readdir | is_dir | unlink]. *)

(** iter 30: unexpected (non-EAGAIN / EWOULDBLOCK / EINTR / EOF)
    errors raised by [Unix.read] inside [Bg_task.drain_fd_to_buf].
    Replaces the previous silent-EOF catch-all that hid genuine read
    errors (EBADF, EIO, ENOMEM, …) and lost any output between the
    error and process exit.  Labels are closed-vocabulary and
    cardinality-bounded:
    - [fd_kind] = [stdout | stderr] (call-site tagged).
    - [error_kind] = [unix_error | other] (typed match arm).
    Total cardinality: 4. *)

(** Build identity git probe failures. Labels:
    [site] = [commit_ts_git_capture | commit_ts_git_status | commit_ts_parse]. *)
val metric_build_identity_probe_failures : string

(** Build identity git probe failures. Labels:
    [site] = [commit_ts_git_capture | commit_ts_git_status | commit_ts_parse]. *)
val metric_distributed_lock_acquire_failed : string
(** #9645: distributed lock acquire retry-budget exhaustions.
    Labels: [key, attempts]. *)

(** IDE read routes that resolved to the shared orphan partition instead of
    [by-url/<canonical-repo>]. Labels: [reason] =
    [no_canonical_url | unmatched | base_unresolved | legacy_default]. *)
val metric_ide_orphan_reads : string

(** #10130: boot-time sweep of save_file_atomic orphan temp files.
    Labels: [size_class = empty | with_data]. *)
val metric_fs_atomic_orphans_cleaned : string

include module type of Otel_identity_metric_names

(** {1 Transport metrics} *)

include module type of Otel_transport_metric_names

(** [masc_keeper_oas_run_timeout_total] counter incremented in the
    runtime FSM each time an [Agent.run] / [run_stream] returns
    [Llm_provider.Retry.Timeout]. The [source] label is typed provider
    timeout phase when OAS exposes one, otherwise [provider]. Free-form
    timeout messages are not reparsed into [max_execution_time] labels.

    Labels: runtime, provider, source. *)
(* Centralized metric constants for inline string replacement. *)

(** Counter incremented when an OAS after-turn response is accepted but
    its response model field is empty. This tracks malformed or partial
    provider response metadata, not keeper tool_access policy decisions. *)
val metric_after_turn_response_model_empty : string

val metric_after_turn_response_model_alias : string
val metric_cost_emit_zero_source : string
val metric_cost_ledger_status : string
(* metric_keeper_meta_read_failures declared earlier in this interface (line 200) *)

(** RFC-0040: sender-side mention dedup decision counter.
    Labels: [outcome] with values
    [skipped|passed|no_target|bypassed]. *)
val metric_mention_dedup_decisions_total : string

(** #20677: incremental telemetry cache fell back to a full re-parse
    (file shrank or rotated under the boundary).  Labels: [store]. *)
val metric_telemetry_cache_rescans : string

(** #20677: bytes folded by incremental telemetry readers.  Labels:
    [store]. *)
val metric_telemetry_scanned_bytes : string
