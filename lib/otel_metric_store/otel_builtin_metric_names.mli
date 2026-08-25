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
    [event_family] (one of [agent_lifecycle] / [task_transition])
    and [event_kind] (the variant). For
    [agent_lifecycle], [event_kind] is one of [join] / [rejoin] /
    [leave] (3 values). For [task_transition],
    [event_kind] uses the 8
    [Masc_domain.task_action_to_string] values: [claim] / [start] /
    [done] / [cancel] / [release] / [submit_for_verification] /
    [approve] / [reject]. Cardinality bound: 11 series (3 + 8).
    Non-zero rate means a production path is firing the lifecycle
    outside an Eio fiber and the corresponding audit/telemetry rows
    are missing — the silent root cause behind the [#10358] 5-tag → 2-tag
    durable-ledger attrition. *)
val metric_workspace_telemetry_drop : string

include module type of Otel_agent_core_metric_names

include module type of Otel_runtime_metric_names

(** {1 Core counters / gauges} *)

include module type of Otel_core_metric_names

(* masc_pool_* series are emitted solely by [Otel_runtime_observables]; no
   store cells are declared here. *)

include module type of Otel_policy_metric_names

(** Total stimuli consumed at turn entry, classified by [stimulus_class].
    Labels: [keeper], [class]
    (board_signal|bootstrap|unsupported).
    Pairs with [masc_keeper_unsupported_stimulus_total] for unsupported-only
    drill-down with payload prefix. *)

(** Unsupported stimuli consumed at turn entry — the dequeued payload
    did not match any known stimulus class. Each increment represents a
    wake -> no_signal gap per #12684. Labels: [keeper]. *)

(** Total supervisor restart attempts for crashed keepers. Labels:
    [keeper]. *)

(** Total supervisor restart outcomes. Labels:
    [keeper, outcome]. Outcome is one of [started | meta_unavailable]. *)

val metric_agent_core_bus_capacity : string
(** Gauge: total queue capacity for live subscribers grouped by
    [bus], [purpose], [capacity], and [overflow]. *)

(** #9632: subprocess executions that exceeded their configured
    timeout. Labels: [program, timeout_sec]. *)
val metric_process_timeout : string

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

include module type of Otel_identity_metric_names

(** {1 Transport metrics} *)

include module type of Otel_transport_metric_names

(** [masc_keeper_agent_core_run_timeout_total] counter incremented in the
    runtime FSM each time an [Agent.run] / [run_stream] returns
    [Llm_provider.Retry.Timeout]. The [source] label is typed provider
    timeout phase when AGENT_CORE exposes one, otherwise [provider]. Free-form
    timeout messages are not reparsed into [max_execution_time] labels.

    Labels: runtime, provider, source. *)
(* Centralized metric constants for inline string replacement. *)

(** Counter incremented when an AGENT_CORE after-turn response is accepted but
    its response model field is empty. This tracks malformed or partial
    provider response metadata. *)
val metric_after_turn_response_model_empty : string

val metric_after_turn_response_model_alias : string
val metric_cost_emit_zero_source : string
val metric_cost_ledger_status : string
(* metric_keeper_meta_read_failures declared earlier in this interface (line 200) *)

(** #20677: incremental telemetry cache fell back to a full re-parse
    (file shrank or rotated under the boundary).  Labels: [store]. *)
val metric_telemetry_cache_rescans : string

(** #20677: bytes folded by incremental telemetry readers.  Labels:
    [store]. *)
val metric_telemetry_scanned_bytes : string

(** A keeper lifecycle event reached the dashboard cache patcher without a
    decodable [event]/[keeper_name] pair, so the cache invalidation it carried
    was dropped. Declared rather than emitted bare so the 0-cell exports while
    the fleet is healthy. *)
val metric_keeper_lifecycle_malformed : string
