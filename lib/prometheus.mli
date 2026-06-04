(** Prometheus-Compatible Metrics for masc.

    Lightweight metrics collection with Prometheus text format export.
    Thread-safe via [Stdlib.Mutex] — works across OCaml 5 domains and
    during module initialisation before any Eio scheduler exists.

    @since 0.4.0 *)

include module type of Prometheus_store

include module type of Prometheus_metric_names


(** #10097: per-(provider, tool) counter for keeper-bound runtime MCP
    omissions.  Paired with a once-per-fingerprint WARN log so logs
    carry structural facts and Prometheus carries frequency.

    RFC-0058 §2.4 / Phase 5.4: renamed from
    `masc_cli_tool_a_mcp_tool_omission_total` to keep provider identity
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
val metric_workspace_claim_post_provision_failures : string
(** Total best-effort claim post-provision hook failures. Labels: [site]
    and [agent_name]. *)

include module type of Prometheus_oas_metric_names

include module type of Prometheus_runtime_metric_names

(** {1 Core counters / gauges} *)

include module type of Prometheus_core_metric_names

include module type of Prometheus_policy_metric_names

(* Inlined from deleted Prometheus_runtime_metric_names (runtime purge). *)
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
    (board_signal|bootstrap|stay_silent_recovery|unsupported).
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
      cycle continues.
    - [outcome=soft_backoff]: strike at or above limit; keeper fiber
      remains alive while provider/runtime cooldown and retry backoff
      throttle later turns.
    - [outcome=promote]: policy allowed keeper death because separate
      liveness evidence exists. Counter reset on any successful turn. *)

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

(** Counter: OAS [Agent_sdk.Event_bus.payload] variants that the
    runtime event bridge did not have an explicit arm for and
    degraded to a kind-only SSE payload via the catch-all in
    [Keeper_event_bridge.native_event_to_json].  Labels: [kind]
    carries [Agent_sdk.Event_bus.payload_kind other] (snake_case,
    one-to-one with the upstream OAS payload constructor name —
    cardinality is bounded by the OAS variant set and grows only
    on upstream pin bumps).

    A non-zero rate means an OAS pin bump shipped a new payload
    variant before the masc consumer was migrated.  The catch-all
    is deliberate (see [Keeper_event_bridge.native_event_to_json])
    but degrades SSE subscribers to a kind-only payload, so this
    counter is the per-process signal that an explicit arm needs
    to be added.  Fix: extend the explicit match in
    [lib/runtime/runtime_event_bridge.ml] for the offending [kind].

    Pairs with the per-occurrence WARN log
    ["oas_event_bridge: kind-only fallback ..."]. *)
val metric_oas_bridge_unmigrated_payload_kind : string

(** Counter: tool-result blocks compacted by
    [Keeper_context_core.sanitize_checkpoint_message] because the
    raw content would have exceeded a budget.  Labels are
    closed-vocabulary (cardinality 6):

    - [action] = [stubbed | truncated].
      [stubbed] replaces the content with a marker string so the
      block contributes essentially zero bytes; [truncated] keeps a
      prefix and appends a cap marker.
    - [reason] = [over_count | over_aggregate_bytes | over_single_byte].
      [over_count] = per-message tool-result count cap reached.
      [over_aggregate_bytes] = adding this result would exceed the
      cumulative tool-result byte budget for the message.
      [over_single_byte] = this single result exceeds the per-result
      byte cap.

    A persistent non-zero rate means operators are losing tool-result
    payload at checkpoint time; the [reason] label tells them which
    cap to revisit (per-result vs aggregate vs count). *)
val metric_keeper_context_tool_result_compacted : string

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
val metric_pricing_catalog_miss : string
val metric_cost_emit_zero_source : string
val metric_cost_ledger_status : string
(* metric_keeper_meta_read_failures declared earlier in this interface (line 200) *)

(** RFC-0040: sender-side mention dedup decision counter.
    Labels: [outcome] with values
    [skipped|passed|no_target|bypassed]. *)
val metric_mention_dedup_decisions_total : string

(** {1 Process monitoring} *)

val set_tool_schema_stats : count:int -> approx_tokens:int -> unit

(* RFC-0217 S4-2 — to_prometheus_text removed (Prometheus /metrics scrape
   retired; metrics export via OTLP push). *)

(** {1 Convenience Functions} *)

val record_request : unit -> unit
val record_task_completed : unit -> unit
val record_task_failed : unit -> unit
val record_error : ?error_type:string -> unit -> unit
val set_active_agents : int -> unit
val set_pending_tasks : int -> unit
val reconcile_active_agents_gauge : string -> unit
val update_uptime : unit -> unit

(** {1 Initialisation}

    Called automatically at module load via [let () = init ()].
    Idempotent — safe to call again. *)
val init : unit -> unit
