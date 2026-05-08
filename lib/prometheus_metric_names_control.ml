(** Private Prometheus metric-name constants split out of [Prometheus].

    Keep these modules pure: string constants only, no observer wiring or
    runtime registration side effects. *)

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
