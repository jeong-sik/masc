let metric_provider_prefix_cache_creation_tokens =
  "masc_provider_prefix_cache_creation_tokens_total"
let metric_provider_prefix_cache_read_tokens =
  "masc_provider_prefix_cache_read_tokens_total"
let metric_tool_call = "masc_tool_call_total"
let metric_tool_call_duration = "masc_tool_call_duration_seconds"
let metric_llm_provider_http_status = "masc_llm_provider_http_status_total"
let metric_llm_provider_request_latency =
  "masc_llm_provider_request_latency_seconds"
let metric_llm_provider_request_latency_clamped =
  "masc_llm_provider_request_latency_clamped_total"
let metric_llm_provider_capability_drops =
  "masc_llm_provider_capability_drops_total"
let metric_llm_provider_cache_hits = "masc_llm_provider_cache_hits_total"
let metric_llm_provider_cache_misses = "masc_llm_provider_cache_misses_total"
let metric_llm_provider_requests_started =
  "masc_llm_provider_requests_started_total"
let metric_llm_provider_errors = "masc_llm_provider_errors_total"
let metric_llm_provider_errors_by_reason =
  "masc_llm_provider_errors_by_reason_total"
let metric_llm_provider_retries = "masc_llm_provider_retries_total"
let metric_llm_provider_input_tokens = "masc_llm_provider_input_tokens_total"
let metric_llm_provider_output_tokens = "masc_llm_provider_output_tokens_total"
let metric_fallback_triggered =
  "masc_fallback_triggered_total"

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
let metric_keeper_quantitative_claim_rejections =
  "masc_keeper_quantitative_claim_rejections_total"
let metric_cascade_strategy_decisions = "masc_cascade_strategy_decisions_total"
let metric_cascade_capacity_events = "masc_cascade_capacity_events_total"

(* RFC-0022 §9 attempt-liveness gate.  Counts would-be (Observe) and
   actual (Enforce) liveness kills broken down by failure class.
   Labels: [kind, mode, provider].

   [observed_total] is the per-attempt finalizer counter regardless of
   outcome (success | kill | wire_error). Useful for the kill-rate
   ratio kill / observed. *)
let metric_cascade_attempt_liveness_kill =
  "masc_cascade_attempt_liveness_kill_total"
let metric_cascade_attempt_liveness_observed =
  "masc_cascade_attempt_liveness_observed_total"
let metric_keeper_invariant_violations = "masc_keeper_invariant_violations_total"
let metric_keeper_fsm_edge_transitions =
  "masc_keeper_fsm_edge_transitions_total"
let metric_keeper_turn_fsm_transitions =
  "masc_keeper_turn_fsm_transitions_total"
let metric_keeper_turn_phase_duration =
  "masc_keeper_turn_phase_duration_seconds"
let metric_keeper_lifecycle_transitions =
  "masc_keeper_lifecycle_transitions_total"
let metric_fsm_guard_violation = "masc_fsm_guard_violation_total"
let metric_keeper_lifecycle_callback_failures =
  "masc_keeper_lifecycle_callback_failures_total"
let metric_memory_pipeline_flushes =
  "masc_memory_pipeline_flushes_total"
let metric_memory_pipeline_flush_records =
  "masc_memory_pipeline_flush_records_total"
let metric_memory_pipeline_flush_duration_seconds =
  "masc_memory_pipeline_flush_duration_seconds"
let metric_keeper_event_bus_drain = "masc_keeper_event_bus_drain_total"
let metric_keeper_supervisor_cleanup_failures =
  "masc_keeper_supervisor_cleanup_failures_total"
(* Increments each time [Keeper_turn_slot.force_release_holder_for] frees
   a slot held by a zombie fiber (typically because the fiber is stuck
   inside an LLM subprocess that did not honour cancellation). Without
   this path the slot stays held until process restart, starving the
   fleet behind the [reactive_turn_semaphore]. Labels: keeper, label
   ([turn] / [autonomous] / [reactive]). A positive rate means the
   force-release path is the only thing draining stuck slots, which is
   itself a signal that the upstream subprocess kill-on-cancel is
   incomplete and worth investigating. *)
let metric_keeper_slot_force_released =
  "masc_keeper_slot_force_released_total"
(* P0-2 (2026-05-07): observability for orphan turn loops.
   [_dropped] increments every time [Keeper_registry.update_entry] is
   called against a missing key (caller raced with deregistration).
   [_orphan_threshold_breached] increments once per breach event when
   the per-keeper drop count crosses [orphan_drop_threshold] inside
   [orphan_drop_window_sec]. Together they let operators tell a
   harmless single-update race from a stuck orphan fiber emitting 30+
   drops per turn. See masc-mcp 2026-05-07 verifier-loop incident. *)
let metric_keeper_registry_update_dropped =
  "masc_keeper_registry_update_dropped_total"
let metric_keeper_registry_orphan_threshold_breached =
  "masc_keeper_registry_orphan_threshold_breached_total"
let metric_keeper_stale_watchdog_tick_failures =
  "masc_keeper_stale_watchdog_tick_failures_total"
let metric_keeper_dead_total = "masc_keeper_dead_total"
(* Self-healing circuit breaker: incremented each time [sweep_and_recover]
   auto-resumes a keeper after its back-off timer has elapsed.  A rate >0
   means the system is self-healing; a zero rate while keepers accumulate
   [auto_resume_after_sec] means the sweep is not firing or the meta write
   is failing. Labels: keeper. *)
let metric_keeper_auto_resumed_total = "masc_keeper_auto_resumed_total"
(* Phase-3.5 health-gate block: incremented when the supervisor skips
   auto-resume because the keeper's cascade is unhealthy (failure ratio
   >= threshold).  Labels: keeper, cascade.  A positive rate means the
   health probe is actively protecting the fleet from resuming into a
   still-failing cascade. *)
let metric_keeper_auto_resume_blocked_total =
  "masc_keeper_auto_resume_blocked_total"
(* Positive signal for the Skip_idle + Woken gate-promotion path added
   by #12271. Increments every time run_smart_heartbeat_gate observes
   that an external wakeup_keeper call cut a Skip_idle backoff sleep
   short and the cycle was resumed (KeeperHeartbeat.tla HeartbeatTick
   action). A zero rate after operator-visible board signals to a Live
   keeper means the fix path is not firing — either the wakeup never
   reached the atomic, or a regression silently re-introduced
   MissedWakeup. Pair with stale_termination_by_class for full
   positive/negative coverage. Labels: keeper. *)
let metric_keeper_skip_idle_wake_resumed =
  "masc_keeper_skip_idle_wake_resumed_total"
let metric_keeper_event_queue_override =
  "masc_keeper_event_queue_override_total"
let metric_keeper_stimulus_consumed =
  "masc_keeper_stimulus_consumed_total"
let metric_keeper_unsupported_stimulus =
  "masc_keeper_unsupported_stimulus_total"
let metric_keeper_near_exhaustion_total = "masc_keeper_near_exhaustion_total"
let metric_keeper_restart_attempts =
  "masc_keeper_restart_attempts_total"
let metric_keeper_restart_outcomes =
  "masc_keeper_restart_outcomes_total"
(* #12801: Liveness Recovery Supervisor — auto-recover Dead keepers
   whose root cause has cleared.  [attempts] increments each time the
   scan selects a Dead keeper for recovery; [outcomes] breaks out the
   result by outcome label (started | not_running | meta_missing |
   meta_read_failed | meta_write_failed). Labels: keeper (for
   attempts) and keeper+outcome (for outcomes). *)
let metric_keeper_liveness_recovery_attempts =
  "masc_keeper_liveness_recovery_attempts_total"
let metric_keeper_liveness_recovery_outcomes =
  "masc_keeper_liveness_recovery_outcomes_total"
(* #12797: Cascade server-error score decay — provider deprioritised
   after recent 5xx events.  Increments each time a provider's server-
   error score drops the effective weight below the skip threshold.
   Labels: provider_key. *)
let metric_cascade_server_error_skip_total =
  "masc_cascade_server_error_skip_total"

(* 2026-05-05 fleet-stuck diagnosis: cascade A → B → A circular fallback
   creates a silent 600s timeout chain when every model in both
   cascades depends on the same provider that has stalled.  This
   counter increments once per [load_catalog] call when any
   fallback_cascade chain forms a cycle.  Labels: cascade (the entry
   point of the cycle).  Operators alert on this counter; cycle
   participants are listed in the WARN log. *)
let metric_cascade_fallback_cycle_detected_total =
  "masc_cascade_fallback_cycle_detected_total"
let metric_provider_health_probe_skipped =
  "masc_provider_health_probe_skipped_total"
let metric_provider_actual_health_status =
  "masc_provider_actual_health_status"
(* #12799: Passive loop detector — keeper emitting only read-only tool
   calls for N consecutive turns.  Labels: keeper. *)
let metric_keeper_passive_loop_detected_total =
  "masc_keeper_passive_loop_detected_total"
let metric_keeper_required_tool_loop_detected_total =
  "masc_keeper_required_tool_loop_detected_total"
let metric_keeper_zombie_loop_detected_total =
  "masc_keeper_zombie_loop_detected_total"
let metric_keeper_required_tool_gate_suppressed_total =
  "masc_keeper_required_tool_gate_suppressed_total"

(* Task-138: Minimum proactive cadence — observability gauges that pair
   with the [keeper_passive_loop_detector] streak counter so operators
   can see "alive but unproductive" keepers in Grafana before the
   detection latch fires.  Labels: keeper. *)
let metric_keeper_consecutive_idle = "masc_keeper_consecutive_idle"
let metric_keeper_last_productive_ts = "masc_keeper_last_productive_ts"
(* PR-M (Leak 9): consecutive [oas_timeout_budget] cycle FAILED strikes
   per keeper. Counter increments on each strike; a strike at
   [outcome=promote] means [Keeper_fiber_crash] was raised so
   [Keeper_supervisor.sweep_and_recover] will respawn the fiber. Without
   the strike→crash promotion these failures repeated silently for
   hours (4h+ zombie keepers observed 2026-04-26). *)
let metric_keeper_oas_timeout_budget_strike =
  "masc_keeper_oas_timeout_budget_strike_total"
let metric_oas_bus_subscriber_stream_depth = "masc_oas_bus_subscriber_stream_depth"
let metric_oas_bus_publish_block_seconds = "masc_oas_bus_publish_block_seconds_total"
let metric_oas_bus_publish = "masc_oas_bus_publish_total"
let metric_runtime_ollama_probe_generate_skips =
  "masc_runtime_ollama_probe_generate_skips_total"
let metric_process_timeout = "masc_process_timeout_total"
let metric_bg_task_sidecar_failures =
  "masc_bg_task_sidecar_failures_total"
let metric_build_identity_probe_failures =
  "masc_build_identity_probe_failures_total"
let metric_distributed_lock_acquire_failed =
  "masc_distributed_lock_acquire_failed_total"

(* #10130: boot-time sweep of [save_file_atomic] orphan temp
   files.  Labels: [size_class = empty | with_data].  The
   [with_data] rate is the interesting operator signal — each
   non-zero orphan represents a silent atomic-save failure
   (SIGKILL / ENFILE mid-write) that dropped the payload. *)
let metric_fs_atomic_orphans_cleaned =
  "masc_fs_atomic_orphans_cleaned_total"

(* #9786: bearer token mismatch — agent [A] presents a token that
   resolves to credential owner [B].  The Auth layer rejects with
   [Unauthorized "No credential found for A (bearer token belongs to B)"],
   but the failure was invisible to Prometheus: dashboards could
   only see cascading downstream rejections (masc_claim_next
   failures, keeper degraded proactive state) without the upstream
   cause.  Labels [expected_agent, actual_agent] keep cardinality
   bounded at the small cross-product of fleet identities. *)
let metric_auth_bearer_token_mismatch =
  "masc_auth_bearer_token_mismatch_total"

(* #10183: strict Auth rejects unknown external tools.  Before this,
   repeated "unknown non-masc tool" denials were only visible by
   grepping logs.  Keep labels bounded: [agent_name] is fleet-sized
   and [tool_class] is a small vocabulary, not the raw tool name. *)
let metric_auth_strict_unknown_tool_denials =
  "masc_auth_strict_unknown_tool_denials_total"

(* #9786 follow-up: boot-time audit counter for credentials
   sharing the same token hash.  Distinct from
   [bearer_token_mismatch]: the mismatch counter fires per
   request, this fires once per boot per detected duplicate
   group.  Operators alert on a non-zero value at all — every
   shared-token group is a routing ambiguity. *)
let metric_auth_credential_token_duplicate =
  "masc_auth_credential_token_duplicate_total"

(* #10304: prevention complement to the duplicate-token audit.
   Boot-time keeper repair increments this once per successfully
   rotated credential, labeled by the old shared token prefix and
   bounded repair scope. *)
let metric_auth_credential_token_rotated =
  "masc_auth_credential_token_rotated_total"
let metric_config_credential_archived_starvation =
  "masc_config_credential_archived_starvation_total"

(* #9786 runtime complement: every [find_credential_by_token]
   lookup that hits N>=2 matches fires this counter.  The
   boot-time audit ({!metric_auth_credential_token_duplicate})
   detects shared tokens once at startup, but operators have no
   visibility on whether subsequent requests actually exercise
   the ambiguity - the silent route-to-first behavior continues
   to fire while the alert is just an open ticket.  This counter
   surfaces the live blast radius (per-request rate) so an
   alerting rule can distinguish "audit warning, no traffic"
   from "duplicate token actively serving the wrong agent".

   Cardinality: [first_match] is the agent_name that wins the
   List.find race (~10 fleet keepers), bounded. *)
let metric_auth_credential_ambiguous_lookup =
  "masc_auth_credential_ambiguous_lookup_total"

(** Silent failure observability (PR-I, 2026-04-25)

   Background: 14 keepers fleet runs for hours producing 0 git_clone calls
   and operators cannot tell from logs *why* — many fallback branches in the
   keeper request path use [| Error _ -> default] / [| None -> fallback]
   without any structured log emit. The unknown-silence symptom.

   These counters surface the live rate of each silent fallback so the
   dashboard can distinguish "code path is dead" from "code path fires
   constantly and silently corrupts identity / risk classification". Each
   silent point gets a distinct counter with [agent] / [reason] labels so
   we can attribute the silence back to a specific keeper.

   Pair these counters with [Log.<area>.warn] emits at the same call sites
   so grep-based debugging works in addition to dashboard alerts. *)
let metric_silent_auth_token_resolve_error =
  "masc_silent_auth_token_resolve_error_total"

let metric_silent_dashboard_actor_fallback =
  "masc_silent_dashboard_actor_fallback_total"

let metric_auth_strict_would_reject =
  "masc_auth_strict_would_reject_total"

let metric_empty_tool_universe_observed =
  "masc_empty_tool_universe_observed_total"

(** Counter for Coord.join identity-normalization outcomes (RFC P3-a).
   Labels: outcome (ok | empty_input | persona_not_found | credential_missing
   | name_ambiguous | ephemeral_suffix_rejected). Non-ok outcomes reject the
   join at the fail-closed gate. Cross-reference with
   [metric_silent_auth_token_resolve_error] for auth/name drift diagnosis. *)
let metric_coord_join_normalize_outcome =
  "masc_coord_join_normalize_outcome_total"
let metric_config_unknown_keys_ignored =
  "masc_config_unknown_keys_ignored_total"
let metric_governance_judge_unparseable =
  "masc_governance_judge_unparseable_total"
let metric_governance_lenient_json_fallback_hit =
  "masc_governance_lenient_json_fallback_hit_total"



(* Centralized from keeper_stale_watchdog.ml.  Originally each metric was
   an inline string literal passed to inc_counter / register_counter.
   Constants make grep/audit trivial and prevent typo-induced metric
   proliferation (a single-character typo creates a new invisible metric). *)
let metric_keeper_stale_termination_total =
  "masc_keeper_stale_termination_total"
let metric_keeper_stale_termination_by_class =
  "masc_keeper_stale_termination_by_class_total"
let metric_keeper_oas_timeout_budget_watchdog_termination =
  "masc_keeper_oas_timeout_budget_watchdog_termination_total"
let metric_keeper_stale_termination_threshold_breached =
  "masc_keeper_stale_termination_threshold_breached_total"
let metric_keeper_stale_termination_batch =
  "masc_keeper_stale_termination_batch_total"
let metric_keeper_stale_broadcast_emit_failures =
  "masc_keeper_stale_broadcast_emit_failures"
let metric_keeper_oas_run_timeout =
  "masc_keeper_oas_run_timeout_total"


(* Centralized metric constants for inline string replacement.
   keeper_hooks_oas.ml, keeper_guards.ml, keeper_execution_receipt.ml,
   keeper_shell_bash.ml, keeper_shell_docker.ml,
   keeper_heartbeat_snapshot.ml, keeper_stay_silent_loop_detector.ml,
   keeper_unified_metrics.ml. *)
let metric_keeper_tool_use_failure =
  "masc_keeper_tool_use_failure_total"
(* #13xxx: keeper dispatch layer denied a tool call because the
   tool is not in the keeper's allowlist (preset drift, deny-list,
   or unknown tool name).  Distinct from [metric_keeper_tool_use_failure]
   (post-execution hook failure) and
   [metric_keeper_turn_gate_rejected_terminal] (pre_tool_use guard
   hard-reject).  Labels:
   - [keeper] — keeper name (fleet-bounded)
   - [tool]   — tool name attempted (registry-bounded, ~100 tools)
   - [reason] — vocabulary:
       "not_in_candidate_set" (unknown / not available to this preset)
       "denied_by_policy"     (explicit deny-list entry)
       "not_in_allow_set"     (tool exists but preset omits it)
   Cardinality: ~16 keepers × ~100 tools × 3 reasons = ~4800 series. *)
let metric_keeper_tool_not_allowed =
  "masc_keeper_tool_not_allowed_total"
let metric_after_turn_response_model_empty =
  "masc_after_turn_response_model_empty_total"
let metric_after_turn_response_model_alias =
  "masc_after_turn_response_model_alias_total"
let metric_pricing_catalog_miss =
  "masc_pricing_catalog_miss_total"
let metric_cost_emit_zero_source =
  "masc_cost_emit_zero_source_total"
let metric_cost_ledger_status =
  "masc_cost_ledger_status_total"
let metric_keeper_turn_gate_rejected_terminal =
  "masc_keeper_turn_gate_rejected_terminal_total"
let metric_keeper_receipt_unmapped_disposition =
  "masc_keeper_receipt_unmapped_disposition_total"
let metric_keeper_bash_network_upgrade =
  "masc_keeper_bash_network_upgrade_total"
let metric_keeper_bash_local_execution =
  "masc_keeper_bash_local_execution_total"
let metric_keeper_docker_runtime_discarded =
  "masc_keeper_docker_runtime_discarded_total"
let metric_keeper_proactive_skip =
  "masc_keeper_proactive_skip_total"
let metric_keeper_stay_silent_loop_detected =
  "masc_keeper_stay_silent_loop_detected_total"
let metric_keeper_usage_trust =
  "masc_keeper_usage_trust_total"
let metric_keeper_usage_anomaly_reason =
  "masc_keeper_usage_anomaly_reason_total"
let metric_keeper_config_env_parse_failures =
  "masc_keeper_config_env_parse_failures_total"
let metric_keeper_post_turn_wirein_failures =
  "masc_keeper_post_turn_wirein_failures_total"
(* metric_keeper_meta_read_failures defined earlier at line 473 (single
   source of truth). Re-binding here would silently shadow without
   changing behavior because the strings are identical, but it makes
   the constant look like it has two declaration sites. *)
let metric_keeper_recurring_failures =
  "masc_keeper_recurring_failures_total"
let metric_keeper_turn_cleanup_failures =
  "masc_keeper_turn_cleanup_failures_total"

(* RFC-0040: sender-side mention dedup decision counter.  Labels:
   [outcome] in [skipped|passed|no_target|bypassed].  Wired from
   [lib/coord.ml] via [Coord_hooks.mention_dedup_decision_fn]. *)
let metric_mention_dedup_decisions_total =
  "masc_mention_dedup_decisions_total"

