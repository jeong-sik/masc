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

let add_key_segment buf s =
  Buffer.add_string buf (string_of_int (String.length s));
  Buffer.add_char buf ':';
  Buffer.add_string buf s

let labels_key (labels : label list) =
  let buf = Buffer.create 32 in
  List.iter (fun (k, v) ->
    add_key_segment buf k;
    add_key_segment buf v
  ) labels;
  Buffer.contents buf

let metric_key name labels =
  let encoded_labels = labels_key labels in
  let buf = Buffer.create (String.length name + String.length encoded_labels + 16) in
  add_key_segment buf name;
  Buffer.add_string buf encoded_labels;
  Buffer.contents buf

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

(* #10682 diagnostic: when EDEADLK fires (PTHREAD_MUTEX_ERRORCHECK
   detects same-thread re-entry on OCaml 5), lock raises Sys_error with
   message "Mutex.lock: Resource deadlock avoided". Without a backtrace,
   the actual re-entrant call site is invisible because [with_lock] is
   used by ~12 sites in this module and is reachable from every read
   tool dispatch. We capture the raw backtrace at the point of failure
   and stash it on a side-channel for the next render so the offending
   site self-documents. The non-failing path is unchanged. *)
let last_deadlock_backtrace : string option Atomic.t = Atomic.make None

let with_lock f =
  let bt0 = Printexc.get_callstack 64 in
  (try Stdlib.Mutex.lock metrics_mutex
   with Sys_error msg as exn ->
     let trace = Printexc.raw_backtrace_to_string bt0 in
     let dump =
       Printf.sprintf "Prometheus.with_lock: %s\nCaller stack:\n%s"
         msg trace
     in
     Atomic.set last_deadlock_backtrace (Some dump);
     Printf.eprintf "[ERROR] [Prometheus] %s\n%!" dump;
     raise exn);
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock metrics_mutex)
    f

(** Read-only accessor for the most recent EDEADLK backtrace captured
    by [with_lock]. Used by diagnostic dumps and tests. *)
let last_deadlock_backtrace_for_test () =
  Atomic.get last_deadlock_backtrace

(** {1 Metric Registration} *)

let register_counter ~name ~help ?(labels=[]) () =
  let key = metric_key name labels in
  with_lock (fun () ->
    if not (Hashtbl.mem metrics key) then
      Hashtbl.add metrics key { name; help; metric_type = Counter; value = 0.0; labels })

let register_gauge ~name ~help ?(labels=[]) () =
  let key = metric_key name labels in
  with_lock (fun () ->
    if not (Hashtbl.mem metrics key) then
      Hashtbl.add metrics key { name; help; metric_type = Gauge; value = 0.0; labels })

let register_histogram ~name ~help ?(labels=[]) () =
  let key = metric_key name labels in
  with_lock (fun () ->
    if not (Hashtbl.mem metrics key) then
      Hashtbl.add metrics key { name; help; metric_type = Histogram; value = 0.0; labels })

(** {1 Metric Updates} *)

let inc_counter name ?(labels=[]) ?(delta=1.0) () =
  let key = metric_key name labels in
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
  let key = metric_key name labels in
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
  let key = metric_key name labels in
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
  let key = metric_key name labels in
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
  let key = metric_key name labels in
  let count_key = metric_key (name ^ "_count") labels in
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

(** #10530: keeper required-tool-contract violations (passive-only or
    text-only turns rejected by the keeper agent loop).
    Labels: keeper_name, kind \in \{passive,text_only\}. *)
let metric_keeper_contract_violations =
  "masc_keeper_contract_violations_total"

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
let metric_keeper_turn_livelock_blocks =
  "masc_keeper_turn_livelock_blocks_total"

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

(* #9933 follow-up: per-turn latency buckets split by the effective
   provider/model/cascade surface.  [metric_keeper_turn_latency_bucket]
   tells operators which keeper is slow; this counter answers the next
   operational question: which provider/cascade/profile is burning the
   timeout budget.  Labels are bounded by fleet size, configured model
   labels, configured cascades, channel vocabulary, and the five bucket
   names from [Keeper_unified_metrics.turn_latency_bucket]. *)
let metric_keeper_turn_latency_by_model_bucket =
  "masc_keeper_turn_latency_by_model_bucket_total"

(* P-DASH-01: provider cooldown skip counter.
   When a cascade's provider is in cooldown and the keeper
   fail-opens to a fallback cascade, increment this counter
   so operators can see how often cooldown is triggering
   cascade switches.  Labels: keeper, from_cascade, to_cascade. *)
let metric_keeper_provider_cooldown_skip =
  "masc_keeper_provider_cooldown_skip_total"

(* P-DASH-01: provider cooldown remaining seconds gauge.
   Exposes the current cooldown duration so operators can see
   which cascade is blocked and for how long without log parsing.
   Labels: keeper, cascade. *)
let metric_keeper_provider_cooldown_remaining_sec =
  "masc_keeper_provider_cooldown_remaining_sec"

(* P-DASH-13: provider block duration histogram.
   Records the duration (in seconds) for which a provider is placed
   in cooldown each time a cooldown is applied or extended.
   Labels: provider. *)
let metric_keeper_provider_block_duration_sec =
  "masc_keeper_provider_block_duration_sec"

(* P-DASH-02: turn queue depth gauge.  Semaphore waiters are
   observable via [autonomous_waiter_snapshot_for_test] but were
   only emitted as a debug log line.  Surfacing as a gauge lets
   operators alert on queue pressure without log parsing.
   Labels: keeper, channel. *)
let metric_keeper_turn_queue_depth =
  "masc_keeper_turn_queue_depth"

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

(* #9770: counter for the [join_required] guard firing in
   [Mcp_server_eio_execute].  Production observed agents calling
   [masc_claim_next] (and similar) without [masc_join] first; the
   guard returns a polite error message but no fleet-wide signal
   exists for "how often does this happen, and which agent / tool
   pair is most affected".  Labels:
     [tool]: tool name that hit the guard (bounded by tool surface
       size, ~50).
     [agent_name]: agent that called the tool (bounded by fleet
       size, ~10).
     [reason]: ["room_uninitialized" | "agent_not_joined"].
   Cardinality: ~50 × ~10 × 2 = ~1000 series, safe for Prometheus. *)
let metric_tool_join_required_guard =
  "masc_tool_join_required_guard_total"

(* #9771: keeper turn-slot semaphore wait timeout counter.

   Production observed multiple keepers ([sangsu], [janitor],
   [ramarama], [qa-king], [taskmaster]) repeatedly skipping turns
   with [semaphore wait > 60s, peers holding slot] — peers holding
   the slot for a long-running OAS call (276s-963s observed) ran
   past the 60s wait budget, every waiting keeper timed out, and
   the WARN log was the only signal.

   Three observable channels at which the timeout fires:
     - [autonomous_queue_head]: fairness-FIFO head wait exceeded
     - [autonomous]: autonomous-track semaphore acquire timed out
     - [turn]: shared turn semaphore acquire timed out

   Labels: [keeper, channel].  Cardinality = ~10 keepers × 3
   channels = ~30 series, well within Prometheus best practice. *)
let metric_keeper_semaphore_wait_timeout =
  "masc_keeper_semaphore_wait_timeout_total"

let metric_timeout_policy_overshoot =
  "masc_timeout_policy_overshoot_total"

(* Keeper compaction (keeper_compact_policy.ml, tool_keeper.ml). *)
let metric_keeper_compactions = "masc_keeper_compactions_total"
let metric_keeper_compaction_ratio_change =
  "masc_keeper_compaction_ratio_change"
let metric_keeper_compaction_saved_tokens =
  "masc_keeper_compaction_saved_tokens_total"
let metric_keeper_operator_compact = "masc_keeper_operator_compact_total"
let metric_keeper_operator_clear = "masc_keeper_operator_clear_total"

(* #9943: per-keeper counter of "compaction triggered but
   resulted in no token reduction".  2026-04-24 audit found
   956/972 (98.4%) of recorded compaction snapshots had
   [compaction_before_tokens = compaction_after_tokens > 0],
   meaning a trigger fired but the strategy returned the same
   token budget — a silent failure mode that
   [masc_keeper_compactions_total] hides because that counter
   is incremented on the trigger rather than the savings.  This
   counter labels by [keeper, trigger] so dashboards separate
   "context_overflow_imminent triggered noop" from "manual
   trigger noop" etc. and operators can attribute blame.  Pair
   with [masc_keeper_compaction_saved_tokens_total] (already
   shipping) — that one tracks the bytes saved by the 1.6%
   that DID save anything; this one tracks the 98.4% that
   ran for nothing. *)
let metric_keeper_compaction_noop =
  "masc_keeper_compaction_noop_total"

(* Tier K5 — observability over the K4c per-keeper tool-emission
   accumulator registry. The registry is process-local; this gauge
   exposes its size so operators can alert on divergence from the
   active keeper count (a leak symptom would be registry size >
   live keeper count without trending down on teardown). *)
let metric_keeper_tool_emission_registry_size =
  "masc_keeper_tool_emission_registry_size"

(* Tier K6 — per-keeper tagged tool-emission push counter. Increments
   each time [Keeper_tool_emission_hook.push] captures a parsed JSON
   tool result into the keeper's accumulator. Lets operators rank
   keepers by multimodal output volume and detect silent emission
   stalls (a keeper that should be emitting goes flat). Labels:
   [keeper]. *)
let metric_keeper_tool_emission_pushes =
  "masc_keeper_tool_emission_pushes_total"

(* #10349: keeper FS path rejection counter.  Pre-fix the
   user-facing read-path rejection strings carried the resolver's
   view of allowed sandbox roots (for example [(roots=[<list>])]
   and [(sandbox roots: [<list>])]) to the LLM.  Combined with
   the keeper identity drift documented in the issue (turn 433:
   contract emitted [masc-improver/Docker] while the resolver
   enumerated [analyst]'s sandbox), the error became a
   side-channel oracle for sibling sandboxes.

   The leak lives strictly in the user-visible string; the
   structured side-channel (Eio.traceln + this counter) keeps
   the rejection observable for operators without echoing the
   roots list back to the LLM.  Labels:
   - [kind] = "out_of_roots" (path resolved outside allowed)
              | "not_found_relative" (relative path matched no root) *)
let metric_keeper_path_rejection =
  "masc_keeper_path_rejection_total"

(* Keeper keepalive (keeper_keepalive.ml). *)
let metric_keeper_heartbeat_successes =
  "masc_keeper_heartbeat_successes_total"
let metric_keeper_heartbeat_failures =
  "masc_keeper_heartbeat_failures_total"
let metric_keeper_cleanup_tracking_failures =
  "masc_keeper_cleanup_tracking_failures_total"
let metric_keeper_dispatch_event_failures =
  "masc_keeper_dispatch_event_failures_total"
let metric_keeper_directive_failures =
  "masc_keeper_directive_failures_total"
let metric_keeper_tool_call_duration =
  "masc_keeper_tool_call_duration_seconds"
let metric_keeper_write_meta_failures =
  "masc_keeper_write_meta_failures_total"
let metric_keeper_meta_read_failures =
  "masc_keeper_meta_read_failures_total"
let metric_keeper_approval_queue_failures =
  "masc_keeper_approval_queue_failures_total"
let metric_keeper_guards_failures =
  "masc_keeper_guards_failures_total"
let metric_keeper_profile_load_failures =
  "masc_keeper_profile_load_failures_total"
let metric_keeper_compact_audit_failures =
  "masc_keeper_compact_audit_failures_total"
let metric_keeper_fs_failures =
  "masc_keeper_fs_failures_total"
let metric_keeper_crash_persistence_failures =
  "masc_keeper_crash_persistence_failures_total"
let metric_keeper_generation_lineage_failures =
  "masc_keeper_generation_lineage_failures_total"
let metric_keeper_keepalive_signal_failures =
  "masc_keeper_keepalive_signal_failures_total"
let metric_keeper_meta_json_failures =
  "masc_keeper_meta_json_failures_total"
let metric_keeper_tools_oas_failures =
  "masc_keeper_tools_oas_failures_total"
let metric_keeper_turn_up_update_failures =
  "masc_keeper_turn_up_update_failures_total"
let metric_keeper_exec_tools_failures =
  "masc_keeper_exec_tools_failures_total"
let metric_keeper_circuit_breaker_trips =
  "masc_keeper_circuit_breaker_trips_total"
let metric_keeper_prompt_failures =
  "masc_keeper_prompt_failures_total"
let metric_keeper_run_context_failures =
  "masc_keeper_run_context_failures_total"
let metric_keeper_shell_ops_failures =
  "masc_keeper_shell_ops_failures_total"
let metric_keeper_tag_dispatch_failures =
  "masc_keeper_tag_dispatch_failures_total"
let metric_keeper_trace_emit_failures =
  "masc_keeper_trace_emit_failures_total"
let metric_keeper_transition_audit_failures =
  "masc_keeper_transition_audit_failures_total"
let metric_keeper_execution_receipt_failures =
  "masc_keeper_execution_receipt_failures_total"
let metric_keeper_llm_bridge_failures =
  "masc_keeper_llm_bridge_failures_total"
let metric_keeper_shell_bash_failures =
  "masc_keeper_shell_bash_failures_total"
let metric_keeper_rollover_failures =
  "masc_keeper_rollover_failures_total"
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
(* #10474: no_tool_capable_provider and proactive cycle outcome counters.
   [metric_keeper_no_tool_provider_total] fires every time a keeper's
   cascade has zero tool-capable providers, labelled by cascade so
   the operator sees which cascade definition needs fixing.
   [metric_keeper_proactive_outcome_total] classifies every scheduled
   autonomous cycle into tool_called | noop | error, giving a fleet-wide
   health ratio in Grafana. *)
let metric_keeper_no_tool_provider =
  "masc_keeper_no_tool_provider_total"
let metric_keeper_proactive_outcome =
  "masc_keeper_proactive_outcome_total"
(* PR-B: keeper turn skipped due to ollama saturation pre-check.
   Labelled by [keeper] and [cascade]. *)
let metric_keeper_ollama_saturation_skip =
  "masc_keeper_ollama_saturation_skip_total"
(* Tool-setup and task-load failures during keeper tool surface assembly.
   task_load: Coord.get_tasks_raw exception while loading current task contract.
   tool_selection: TopK_llm or tool discovery exception during per-turn tool set assembly. *)
let metric_keeper_task_load_failures =
  "masc_keeper_task_load_failures_total"
let metric_keeper_tool_selection_failures =
  "masc_keeper_tool_selection_failures_total"
let metric_keeper_tool_policy_failures =
  "masc_keeper_tool_policy_failures_total"
let metric_keeper_reconcile_failures =
  "masc_keeper_reconcile_failures_total"
let metric_keeper_decision_audit_flush_failures =
  "masc_keeper_decision_audit_flush_failures_total"
let metric_keeper_oas_cancel =
  "masc_keeper_oas_cancel_total"
let metric_keeper_claim_auto_provision =
  "masc_keeper_claim_auto_provision_total"
let metric_egress_audit_missing =
  "masc_egress_audit_missing_total"
let metric_egress_audit_stale_orphan =
  "masc_egress_audit_stale_orphan_total"
let metric_keeper_toml_invalid =
  "masc_keeper_toml_invalid_total"
let metric_keeper_persona_drift_missing =
  "masc_keeper_persona_drift_missing_total"
let metric_keeper_room_init_failures =
  "masc_keeper_room_init_failures_total"
let metric_keeper_presence_sync_failures =
  "masc_keeper_presence_sync_failures_total"
let metric_keeper_self_preservation_universal =
  "masc_keeper_self_preservation_universal_total"
let metric_keeper_stale_storm_paused =
  "masc_keeper_stale_storm_paused_total"
let metric_keeper_oas_timeout_budget_loop_paused =
  "masc_keeper_oas_timeout_budget_loop_paused_total"
let metric_keeper_cycle_exceptions =
  "masc_keeper_cycle_exceptions_total"
let metric_keeper_snapshot_write_failures =
  "masc_keeper_snapshot_write_failures_total"
let metric_keeper_sse_broadcast_failures =
  "masc_keeper_sse_broadcast_failures_total"
let metric_keeper_room_heartbeat_failures =
  "masc_keeper_room_heartbeat_failures_total"
let metric_keeper_turn_metrics_snapshot_failures =
  "masc_keeper_turn_metrics_snapshot_failures_total"
let metric_keeper_oas_execution_errors =
  "masc_keeper_oas_execution_errors_total"
let metric_keeper_episode_create_failures =
  "masc_keeper_episode_create_failures_total"
let metric_keeper_supervisor_sweep_failures =
  "masc_keeper_supervisor_sweep_failures_total"
let metric_keeper_toml_reconcile_sweep_failures =
  "masc_keeper_toml_reconcile_sweep_failures_total"
let metric_keeper_tool_usage_flush_failures =
  "masc_keeper_tool_usage_flush_failures_total"
let metric_keeper_turn_livelock_blocks =
  "masc_keeper_turn_livelock_blocks_total"
let metric_keeper_turn_timeout_committed =
  "masc_keeper_turn_timeout_committed_total"
let metric_keeper_turn_error_after_tools =
  "masc_keeper_turn_error_after_tools_total"
let metric_keeper_cascade_sync_failures =
  "masc_keeper_cascade_sync_failures_total"
let metric_keeper_thinking_persist_failures =
  "masc_keeper_thinking_persist_failures_total"
let metric_keeper_checkpoint_failures =
  "masc_keeper_checkpoint_failures_total"
let metric_keeper_memory_write_failures =
  "masc_keeper_memory_write_failures_total"
let metric_keeper_write_meta_cycle_failures =
  "masc_keeper_write_meta_cycle_failures_total"
let metric_keeper_alert_persist_failures =
  "masc_keeper_alert_persist_failures_total"
let metric_keeper_metrics_sse_failures =
  "masc_keeper_metrics_sse_failures_total"let metric_keeper_session_cleanup_failures =
  "masc_keeper_session_cleanup_failures_total"
let metric_keeper_chat_store_failures =
  "masc_keeper_chat_store_failures_total"
let metric_keeper_observation_query_failures =
  "masc_keeper_observation_query_failures_total"
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

(* #9520: durable coverage-gap records must also have an alertable
   Prometheus surface.  The labels deliberately avoid raw paths and
   error strings; [source], [producer], [dashboard_surface], and
   [stale_reason] are bounded vocabularies owned by telemetry
   producers. *)
let metric_telemetry_coverage_gap =
  "masc_telemetry_coverage_gap_total"

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

(* #10942 mirror for masc_oas_bridge cancel branch.  Same bucket
   semantics as [masc_keeper_oas_cancel_total] (fast/short_tail/
   mid_tail/long_mid/long_tail) so PromQL can union the two
   sources by [bucket] for a fleet-wide bimodal view of cancels.
   [caller] preserves the timeout-counter pairing so each caller's
   timeout vs cancel populations stay separable. *)
let metric_oas_bridge_cancel =
  "masc_oas_bridge_cancel_total"


(* OAS event relay (oas_event_bridge.ml).  Metric strings keep the
   historical [oas_sse_*] prefix for Grafana/alert continuity; renaming
   the operational contract is deferred to a separate PR with a
   dashboard migration plan. *)
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
let metric_sse_broadcast_failures = "masc_sse_broadcast_failures_total"
let metric_sse_external_subscriber_callback_failures =
  "masc_sse_external_subscriber_callback_failures_total"
let metric_oas_sse_relay_drop_marker_failures =
  "masc_oas_sse_relay_drop_marker_failures_total"
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
(* PR-0.2.A (RFC 2026-04-masc-ide-strategy): generic cache hit/miss
   counters, labelled by [cache] = "eio" | "dashboard".  Distinct from
   the WS-specific parse/bytes cache counters above; these track the
   filesystem-backed [Cache_eio] and the dashboard in-memory
   stale-while-revalidate cache. *)
let metric_cache_hits_total = "masc_cache_hits_total"
let metric_cache_misses_total = "masc_cache_misses_total"
let metric_ws_client_buffered_bytes = "masc_ws_client_buffered_bytes"
let metric_ws_client_acks = "masc_ws_client_acks_total"
let metric_ws_throttled_deliveries = "masc_ws_throttled_deliveries_total"
let metric_ws_slice_fanout_skipped = "masc_ws_slice_fanout_skipped_total"
let metric_ws_bytes_sent = "masc_ws_bytes_sent_total"
let metric_grpc_bytes_sent = "masc_grpc_bytes_sent_total"
let metric_ws_delta_built = "masc_ws_delta_built_total"
let metric_ws_message_bytes = "masc_ws_message_bytes"
(* Backlog-replay attribution: every gRPC Subscribe RPC reads
   [.masc/backlog.jsonl] from disk before the live broadcast hook
   takes over.  These two counters separate replay cost from live
   delivery so a Subscribe burst can be billed against backlog IO,
   not [grpc_bytes_sent] / [grpc_events_delivered] which lump init
   + replay + live into one bucket. *)
let metric_grpc_backlog_replay_lines_scanned =
  "masc_grpc_backlog_replay_lines_scanned_total"
let metric_grpc_backlog_replay_events_replayed =
  "masc_grpc_backlog_replay_events_replayed_total"

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

(* PR-0.2.D: OCaml GC quick_stat sampler gauges.  Populated by
   [Gc_sampler.run] from the runtime [Gc.quick_stat ()] once per
   sampling interval.  Names follow the [masc_gc_*_words] /
   [masc_gc_*] convention so PromQL queries can group on the
   [masc_gc_] prefix.  Cumulative counters are exposed as Gauge
   because they are read as point-in-time runtime snapshots; PromQL
   [rate()] still works on monotonic-by-construction gauges. *)
let metric_gc_minor_words = "masc_gc_minor_words"
let metric_gc_major_words = "masc_gc_major_words"
let metric_gc_heap_words = "masc_gc_heap_words"
let metric_gc_live_words = "masc_gc_live_words"
let metric_gc_compactions = "masc_gc_compactions"
let metric_gc_promoted_words = "masc_gc_promoted_words"

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
let metric_llm_provider_capability_drops =
  "masc_llm_provider_capability_drops_total"
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
let metric_cascade_strategy_decisions = "masc_cascade_strategy_decisions_total"
let metric_cascade_capacity_events = "masc_cascade_capacity_events_total"
let metric_keeper_invariant_violations = "masc_keeper_invariant_violations_total"
let metric_keeper_fsm_edge_transitions =
  "masc_keeper_fsm_edge_transitions_total"
let metric_keeper_turn_fsm_transitions =
  "masc_keeper_turn_fsm_transitions_total"
let metric_keeper_lifecycle_transitions =
  "masc_keeper_lifecycle_transitions_total"
let metric_fsm_guard_violation = "masc_fsm_guard_violation_total"
let metric_keeper_lifecycle_callback_failures =
  "masc_keeper_lifecycle_callback_failures_total"
let metric_keeper_event_bus_drain = "masc_keeper_event_bus_drain_total"
let metric_keeper_supervisor_cleanup_failures =
  "masc_keeper_supervisor_cleanup_failures_total"
let metric_keeper_stale_watchdog_tick_failures =
  "masc_keeper_stale_watchdog_tick_failures_total"
let metric_keeper_dead_total = "masc_keeper_dead_total"
(* Self-healing circuit breaker: incremented each time [sweep_and_recover]
   auto-resumes a keeper after its back-off timer has elapsed.  A rate >0
   means the system is self-healing; a zero rate while keepers accumulate
   [auto_resume_after_sec] means the sweep is not firing or the meta write
   is failing. Labels: keeper. *)
let metric_keeper_auto_resumed_total = "masc_keeper_auto_resumed_total"
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
(* #12799: Passive loop detector — keeper emitting only read-only tool
   calls for N consecutive turns.  Labels: keeper. *)
let metric_keeper_passive_loop_detected_total =
  "masc_keeper_passive_loop_detected_total"
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


(* Centralized metric constants for inline string replacement.
   keeper_hooks_oas.ml, keeper_guards.ml, keeper_execution_receipt.ml,
   keeper_shell_bash.ml, keeper_shell_docker.ml,
   keeper_heartbeat_snapshot.ml, keeper_stay_silent_loop_detector.ml,
   keeper_unified_metrics.ml. *)
let metric_keeper_tool_use_failure =
  "masc_keeper_tool_use_failure_total"
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
  (* PR-0.2.D: OCaml runtime GC sampler gauges.  See [Gc_sampler]. *)
  add metric_gc_minor_words
    "Cumulative words allocated in the minor heap since program start \
     (from Gc.quick_stat)" Gauge;
  add metric_gc_major_words
    "Cumulative words allocated in the major heap since program start \
     (from Gc.quick_stat)" Gauge;
  add metric_gc_heap_words
    "Current size of the major heap in words (from Gc.quick_stat)" Gauge;
  add metric_gc_live_words
    "Live words in the major heap at last sample (from Gc.quick_stat)" Gauge;
  add metric_gc_compactions
    "Number of major-heap compactions since program start \
     (from Gc.quick_stat)" Gauge;
  add metric_gc_promoted_words
    "Cumulative words promoted from minor to major heap since program \
     start (from Gc.quick_stat)" Gauge;
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
  add metric_keeper_turn_livelock_blocks
    "Total keeper turn dispatches blocked by the stuck-turn livelock guard \
     (labels: keeper, reason=attempts_exhausted|stuck_age_exceeded)"
    Counter;
  (* #9943: per-keeper turn latency bucket distribution.  Each
     completed turn increments exactly one bucket.  Bucket vocabulary
     [under_60s | 60-300s | 300-600s | 600-1200s | over_1200s]. *)
  add metric_keeper_turn_latency_bucket
    "Total keeper turn completions, bucketed by latency (labels: keeper, \
     bucket=under_60s|60-300s|300-600s|600-1200s|over_1200s)"
    Counter;
  add metric_keeper_turn_latency_by_model_bucket
    "Total keeper turn completions, bucketed by latency and effective \
     model surface (labels: keeper, channel, provider_kind, model_used, \
     resolved_model_id, cascade_profile, \
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
  add metric_tool_join_required_guard
    "Total join-required guard rejections before tool execution \
     (labels: tool, agent_name, reason=room_uninitialized|agent_not_joined)"
    Counter;
  add metric_keeper_turn_queue_depth
    "Current keeper turn wait queue depth (labels: channel=autonomous_queue)"
    Gauge;
  (* P-DASH-13: provider block duration histogram.
     Records the duration (in seconds) for which a provider is placed in
     cooldown each time a cooldown is applied or extended.  Labels: provider. *)
  register_histogram ~name:metric_keeper_provider_block_duration_sec
    ~help:"Duration in seconds for which a provider is placed into cooldown \
           (observed each time a cooldown is applied or extended). Labels: provider." ();
  add metric_timeout_policy_overshoot
    "Total cooperative-cancel timeout overshoots \
     (labels: layer, origin)"
    Counter;
  (* Keeper compaction metrics — emitted by keeper_compact_policy.ml *)
  add metric_keeper_compactions
    "Total keeper compactions performed" Counter;
  add metric_keeper_compaction_ratio_change
    "Context ratio change after compaction (pre - post)" Gauge;
  add metric_keeper_compaction_saved_tokens
    "Total tokens removed by keeper context compaction" Counter;
  (* #9943: noop compactions — trigger fired but strategy did
     not reduce token budget. *)
  add metric_keeper_compaction_noop
    "Total compaction snapshots where before_tokens == \
     after_tokens > 0 (compaction triggered but produced no \
     savings; labels: keeper, trigger)"
    Counter;
  (* K5: per-keeper tool-emission accumulator registry size.
     Updated by Keeper_tool_emission_hook on register/drop. *)
  add metric_keeper_tool_emission_registry_size
    "Number of keepers with a registered tool-emission \
     accumulator (Tier K4c per-keeper isolation registry size)"
    Gauge;
  (* K6: per-keeper tagged tool-emission push count. *)
  add metric_keeper_tool_emission_pushes
    "Total tagged tool results captured into the K4c per-keeper \
     accumulator (labels: keeper)"
    Counter;
  (* Operator-initiated overflow recovery — emitted by tool_keeper.ml *)
  add metric_keeper_operator_compact
    "Total operator-invoked masc_keeper_compact calls (labels: result=ok|no_checkpoint|precondition|not_found)" Counter;
  add metric_keeper_operator_clear
    "Total operator-invoked masc_keeper_clear calls (labels: preserve_system=true|false)" Counter;
  (* Keeper heartbeat metrics — emitted by keeper_keepalive.ml *)
  add metric_keeper_heartbeat_successes
    "Total keeper heartbeat successes" Counter;
  add metric_keeper_heartbeat_failures
    "Total keeper heartbeat failures (labels: keeper, site)" Counter;
  add metric_keeper_cleanup_tracking_failures
    "Total keeper cleanup_tracking failures in heartbeat finally \
     (labels: keeper, site)" Counter;
  register_histogram ~name:metric_keeper_tool_call_duration
    ~help:"Keeper tool call latency in seconds, labeled by keeper, provider, tool, and outcome" ();
  add metric_provider_prefix_cache_creation_tokens
    "Total provider prefix cache creation tokens (Anthropic)" Counter;
  add metric_provider_prefix_cache_read_tokens
    "Total provider prefix cache read tokens (Anthropic)" Counter;
  add metric_tool_call
    "Total keeper tool calls labeled by provider, tool, and outcome" Counter;
  (* PR-0.2.C: pre-register cold/warm phase rows so /metrics shows a
     zero-value baseline before the first observation. The phase label
     is decided at observe-site in [Otel_dispatch_hook] based on a
     module-level startup time threshold. *)
  register_histogram ~name:metric_tool_call_duration
    ~help:"Tool call latency in seconds (phase=cold|warm)"
    ~labels:[("phase", "cold")] ();
  register_histogram ~name:metric_tool_call_duration
    ~help:"Tool call latency in seconds (phase=cold|warm)"
    ~labels:[("phase", "warm")] ();
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
  add metric_llm_provider_capability_drops
    "Total OAS capability drops from LLM providers, labeled by model and field"
    Counter;
  add metric_fallback_triggered
    "Total fallback events across the LLM cascade pipeline, labeled by kind \
     (cross_cascade|cascade_empty|capability_drop|cli_unsupported|...) and detail"
    Counter;
  (* Orphan metrics — used via inc_counter/set_gauge but previously
     never registered.  Auto-create still works, but registering here
     gives them a HELP description in /metrics output and a zero-value
     baseline so dashboards see "0" instead of "no data" before the
     first observation. *)
  add metric_keeper_write_meta_failures
    "Total keeper meta-file write failures, labeled by keeper and phase"
    Counter;
  add metric_keeper_meta_read_failures
    "Total keeper meta-file read/parse failures, labeled by keeper and site"
    Counter;
  add metric_keeper_approval_queue_failures
    "Total keeper approval queue failures, labeled by keeper and site"
    Counter;
  add metric_keeper_guards_failures
    "Total keeper guard warnings, labeled by keeper and site"
    Counter;
  add metric_keeper_profile_load_failures
    "Total keeper profile/TOML load failures, labeled by site"
    Counter;
  add metric_keeper_compact_audit_failures
    "Total keeper compact audit failures (persist/prune/handle), labeled by keeper and site"
    Counter;
  add metric_keeper_fs_failures
    "Total keeper filesystem operation failures (ensure_dir/save_atomic), labeled by path and site"
    Counter;
  add metric_keeper_crash_persistence_failures
    "Total keeper crash/sp persistence write failures, labeled by site"
    Counter;
  add metric_keeper_generation_lineage_failures
    "Total keeper generation lineage failures (index append/manifest save), labeled by keeper and site"
    Counter;
  add metric_keeper_keepalive_signal_failures
    "Total keeper keepalive signal failures (board capped/late-event rejected), labeled by keeper and site"
    Counter;
  add metric_keeper_meta_json_failures
    "Total keeper meta JSON failures (seed parse/unknown keys), labeled by site"
    Counter;
  add metric_keeper_tools_oas_failures
    "Total keeper OAS tool failures (blocked/error result/deadlock), labeled by tool and site"
    Counter;
  add metric_keeper_turn_up_update_failures
    "Total keeper turn-up update failures (prompt cap/sandbox validation/preflight), labeled by keeper and site"
    Counter;
  add metric_keeper_exec_tools_failures
    "Total keeper exec tool failures (malformed structured payload), labeled by keeper and tool"
    Counter;
  add metric_keeper_circuit_breaker_trips
    "Total keeper failure circuit breaker trips, labeled by keeper and failure_type"
    Counter;
  add metric_keeper_prompt_failures
    "Total keeper prompt render failures, labeled by prompt name"
    Counter;
  add metric_keeper_run_context_failures
    "Total keeper run context failures (checkpoint save), labeled by keeper"
    Counter;
  add metric_keeper_shell_ops_failures
    "Total keeper shell operation failures (R2 blocked), labeled by keeper"
    Counter;
  add metric_keeper_tag_dispatch_failures
    "Total keeper tag dispatch exceptions, labeled by tag"
    Counter;
  add metric_keeper_trace_emit_failures
    "Total keeper trace emit failures, labeled by keeper"
    Counter;
  add metric_keeper_transition_audit_failures
    "Total keeper transition audit store failures, labeled by site"
    Counter;
  add metric_keeper_execution_receipt_failures
    "Total keeper execution receipt failures (unmapped/emit failed/stale broadcast), labeled by keeper and site"
    Counter;
  add metric_keeper_llm_bridge_failures
    "Total keeper LLM bridge failures (timeout/cancelled/error), labeled by site. \
     The bridge is a generic timeout helper that does not receive keeper context; \
     keeper attribution is recovered from the surrounding Log.Keeper line."
    Counter;
  add metric_keeper_shell_bash_failures
    "Total keeper shell bash blockages (destructive/hard mode/generic), labeled by keeper and site"
    Counter;
  add metric_keeper_rollover_failures
    "Total keeper rollover failures (lineage append, checkpoint save, invalid trace ID), labeled by keeper and site"
    Counter;
  add metric_keeper_lifecycle_dispatch_rejections
    "Total post-turn lifecycle dispatch rejections, labeled by keeper and event"
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
  add metric_keeper_dead_total
    "Total keeper transitions to Dead phase after the supervisor exhausts \
     max_restarts. Labeled by keeper and reason. Any rate >0 is operator-\
     actionable: the supervisor will not retry the keeper."
    Counter;
  add metric_keeper_auto_resumed_total
    "Total keepers auto-resumed by the self-healing circuit breaker after \
     the back-off timer elapsed. Labeled by keeper. A positive rate means \
     the system is self-healing from transient provider outages."
    Counter;
  add metric_keeper_supervisor_cleanup_failures
    "Total supervisor finally-cleanup failures suppressed to avoid \
     Fun.Finally_raised. Labeled by keeper."
    Counter;
  add metric_keeper_stale_watchdog_tick_failures
    "Total stale watchdog tick failures suppressed during poll. Labeled by keeper."
    Counter;
  add metric_keeper_skip_idle_wake_resumed
    "Total cycles where an external wakeup_keeper / board signal cut a \
     Skip_idle backoff sleep short and the heartbeat cycle was resumed \
     (cycle_continues_after_wake -> true). Positive signal for the \
     #12271 fix; pairs with masc_keeper_stale_termination_by_class_total \
     {class=idle_turn} which should drop in proportion. Labels: keeper."
    Counter;
  add metric_keeper_event_queue_override
    "RFC-0020 Rule 2 — total times run_smart_heartbeat_gate forced \
     Heartbeat_smart.Emit because the Event Layer queue \
     (Keeper_registry.event_queue_snapshot) was non-empty. Pairs with \
     masc_keeper_skip_idle_wake_resumed: skip-idle-resumed measures the \
     fiber_wakeup hint path, this measures the queue payload path. \
     Labels: keeper."
    Counter;
  add metric_keeper_stimulus_consumed
    "Total stimuli consumed at turn entry, classified by stimulus_class. \
     Labels: keeper, class (board_signal|bootstrap|unsupported). \
     Pairs with masc_keeper_unsupported_stimulus_total for unsupported-only \
     drill-down with payload prefix."
    Counter;
  add metric_keeper_unsupported_stimulus
    "Unsupported stimuli consumed at turn entry — the dequeued payload \
     did not match any known stimulus class. Each increment represents a \
     wake -> no_signal gap per #12684. Labels: keeper."
    Counter;
  add metric_keeper_near_exhaustion_total
    "Total keeper restart attempts at restart_count = max_restarts - 1, \
     i.e. one failure away from Dead. Soft pre-warning; labeled by keeper."
    Counter;
  add metric_keeper_lifecycle_transitions
    "Total keeper lifecycle phase transitions emitted only when the registry \
     phase changes. Labeled by keeper, from_phase, and to_phase; deliberately \
     omits event/reason payloads to keep cardinality bounded."
    Counter;
  add metric_keeper_restart_attempts
    "Total supervisor restart attempts for crashed keepers. Labeled by keeper."
    Counter;
  add metric_keeper_restart_outcomes
    "Total supervisor restart outcomes. Labeled by keeper and bounded \
     outcome=started|meta_unavailable."
    Counter;
  add metric_keeper_liveness_recovery_attempts
    "#12801 Total Liveness Recovery Supervisor attempts to auto-recover Dead \
     keepers whose root cause has cleared. Labeled by keeper."
    Counter;
  add metric_keeper_liveness_recovery_outcomes
    "#12801 Total Liveness Recovery Supervisor outcomes. Labeled by keeper \
     and outcome=started|not_running|meta_missing|meta_read_failed|meta_write_failed."
    Counter;
  add metric_cascade_server_error_skip_total
    "#12797 Total cascade label-ranking skips triggered by recent server \
     error (5xx) score decay. Labeled by provider_key."
    Counter;
  add metric_keeper_passive_loop_detected_total
    "#12799 Total passive-loop detections: keeper issued only read-only tool \
     calls for N consecutive turns. Labeled by keeper."
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
  add metric_keeper_no_tool_provider
    "Total no_tool_capable_provider errors. Labeled by keeper and cascade."
    Counter;
  add metric_keeper_proactive_outcome
    "Total proactive cycle outcomes. Labeled by keeper and \
     outcome=tool_called|noop|error."
    Counter;
  add metric_keeper_ollama_saturation_skip
    "Total keeper turns skipped because the resolved cascade is \
     ollama-only and the /api/ps probe reported zero available slots. \
     Labeled by keeper and cascade."
    Counter;
  add metric_keeper_task_load_failures
    "Total Coord.get_tasks_raw exceptions while loading current task contract. \
     Labeled by keeper and phase=task_contract_load."
    Counter;
  add metric_keeper_tool_selection_failures
    "Total tool selection exceptions during per-turn tool set assembly. \
     Labeled by keeper and phase=topk_llm|tool_discovery."
    Counter;
  add metric_keeper_tool_policy_failures
    "Total tool-policy preset resolution failures (e.g. policy_config_not_loaded). \
     Labels: site, preset. The policy layer runs at module-init and preset \
     resolution time so it does not carry keeper context; keeper attribution \
     is recovered from the surrounding Log.Keeper line."
    Counter;
  add metric_keeper_reconcile_failures
    "Total current-task reconciliation failures. \
     Labeled by keeper and phase=resolve_agent|task_id_parse|owned_tasks_query."
    Counter;
  add metric_keeper_decision_audit_flush_failures
    "Total decision audit ring-buffer flush failures causing audit data loss. \
     Labeled by keeper."
    Counter;
  add metric_keeper_oas_cancel
    "Total OAS execution cancellations in keeper_llm_bridge. \
     Labeled by bucket (timeout classification)."
    Counter;
  add metric_keeper_claim_auto_provision
    "Total task-claim auto-provision outcomes during keeper bootstrap. \
     Labeled by outcome and agent_name."
    Counter;
  add metric_egress_audit_missing
    "Total egress audit entries where the keeper has no audit record. \
     Labeled by keeper."
    Counter;
  add metric_egress_audit_stale_orphan
    "Total egress audit entries that are stale or orphaned. \
     Labeled by keeper."
    Counter;
  add metric_keeper_toml_invalid
    "Total keeper TOML config parse failures falling back to persona. \
     Labeled by keeper and reason."
    Counter;
  add metric_keeper_persona_drift_missing
    "Total keeper persona file missing at expected path (config drift). \
     Labeled by keeper."
    Counter;
  add metric_keeper_room_init_failures
    "Total supervisor room initialization failures during keeper bootstrap. \
     Labeled by keeper."
    Counter;
  add metric_keeper_presence_sync_failures
    "Total supervisor presence sync failures after room init. \
     Labeled by keeper."
    Counter;
  add metric_keeper_self_preservation_universal
    "Total self-preservation UNIVERSAL suppression events where all \
     keepers in a cohort are suppressed and auto-recovery is OFF. \
     Labeled by cohort (dominant failure key)."
    Counter;
  add metric_keeper_stale_storm_paused
    "Total keepers auto-paused due to stale termination storms. \
     Labeled by keeper."
    Counter;
  add metric_keeper_oas_timeout_budget_loop_paused
    "Total keepers auto-paused due to repeated OAS timeout budget \
     exhaustion. Labeled by keeper."
    Counter;
  add metric_keeper_cycle_exceptions
    "Total unhandled exceptions caught by the keeper main cycle loop. \
     Labeled by keeper."
    Counter;
  add metric_keeper_snapshot_write_failures
    "Total heartbeat snapshot persistence failures causing metric \
     data loss. Labeled by keeper."
    Counter;
  add metric_keeper_sse_broadcast_failures
    "Total in-turn heartbeat SSE broadcast failures. Labeled by keeper."
    Counter;
  add metric_keeper_room_heartbeat_failures
    "Total room heartbeat failures (consecutive, leads to crash). \
     Labeled by keeper."
    Counter;
  add metric_keeper_turn_metrics_snapshot_failures
    "Total metrics snapshot write failures after keeper turns. \
     Labeled by keeper and site."
    Counter;
  add metric_keeper_oas_execution_errors
    "Total OAS execution errors (non-cancellation) in keeper_llm_bridge. \
     Labeled by keeper."
    Counter;
  add metric_keeper_episode_create_failures
    "Total episode creation failures in keeper_agent_memory_episode. \
     Labeled by keeper."
    Counter;
  add metric_keeper_supervisor_sweep_failures
    "Total supervisor sweep failures in keeper_runtime periodic beat. \
     Labeled by origin."
    Counter;
  add metric_keeper_toml_reconcile_sweep_failures
    "Total TOML reconcile sweep failures in keeper_runtime periodic beat. \
     Labeled by origin."
    Counter;
  add metric_keeper_tool_usage_flush_failures
    "Total tool usage JSONL flush failures in keeper_registry. \
     Labeled by keeper."
    Counter;
  add metric_keeper_turn_livelock_blocks
    "Total turn dispatches blocked by livelock guard in keeper_unified_turn."
    Counter;
  add metric_keeper_turn_timeout_committed
    "Total wall-clock turn timeouts after committed mutating tools. \
     Labeled by keeper."
    Counter;
  add metric_keeper_turn_error_after_tools
    "Total provider errors after committed mutating tool calls. \
     Labeled by keeper."
    Counter;
  add metric_keeper_cascade_sync_failures
    "Total cascade state synchronization failures (pause/resume/auto-pause). \
     Labeled by keeper and site."
    Counter;
  add metric_keeper_thinking_persist_failures
    "Total thinking content persistence failures in keeper_agent_run. \
     Labeled by keeper."
    Counter;
  add metric_keeper_checkpoint_failures
    "Total OAS checkpoint save or missing-checkpoint failures. \
     Labeled by keeper."
    Counter;
  add metric_keeper_memory_write_failures
    "Total memory write failures (notes/kinds) in keeper_agent_run. \
     Labeled by keeper."
    Counter;
  add metric_keeper_write_meta_cycle_failures
    "Total write_meta failures after turn/cycle in keeper_unified_turn. \
     Labeled by keeper and site."
    Counter;
  add metric_keeper_alert_persist_failures
    "Total alert JSONL write failures (alert/failed-channels/deadletter). \
     Labeled by kind."
    Counter;
  add metric_keeper_metrics_sse_failures
    "Total SSE broadcast failures during metrics compaction/handoff. \
     Labeled by kind."
    Counter;
  add metric_keeper_dispatch_event_failures
    "Total keeper state machine dispatch_event failures in supervisor. \
     Labeled by event type."
    Counter;
  add metric_keeper_directive_failures
    "Total gRPC directive routing failures — target agent not in registry \
     or directive malformed (labels: keeper, site)" Counter;
  add metric_keeper_session_cleanup_failures
    "Total session directory cleanup failures during keeper teardown."
    Counter;
  add metric_keeper_chat_store_failures
    "Total chat store append/load failures. Labeled by operation."
    Counter;
  add metric_keeper_observation_query_failures
    "Total world observation query failures (backlog counts, active agents, \
     board events). Labeled by operation."
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
  add metric_keeper_contract_violations
    "Keeper turns rejected for required-tool-contract violations (labels: keeper_name, kind={passive|text_only}). #10530."
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
    "Cumulative seconds spent inside Agent_sdk.Event_bus.publish when routed \
     through Oas_bus_instrument.publish. A sustained ramp indicates a \
     subscriber drain loop has fallen behind and publishers are blocking \
     on Eio.Stream.add."
    Counter;
  add metric_oas_bus_publish
    "Total Agent_sdk.Event_bus.publish calls routed through \
     Oas_bus_instrument.publish."
    Counter;
  add metric_runtime_ollama_probe_generate_skips
    "Total Ollama runtime probes that intentionally skipped /api/generate. \
     Labeled by reason=status_only|model_unloaded|ps_error|no_effective_model|policy_skip."
    Counter;
  add metric_process_timeout
    "Total subprocess executions that exceeded their configured timeout. \
     Labeled by program and timeout_sec."
    Counter;
  add metric_distributed_lock_acquire_failed
    "Total distributed lock acquire exhaustions. Labeled by key and attempts. \
     A non-zero rate indicates lock contention exhausted the retry budget."
    Counter;
  (* #10130: boot-time sweep of save_file_atomic orphans. *)
  add metric_fs_atomic_orphans_cleaned
    "Total save_file_atomic orphan temp files cleaned at boot \
     (labels: size_class=empty|with_data).  [with_data] rate > 0 \
     indicates silent atomic-save failures (SIGKILL / ENFILE) that \
     dropped payloads; moved to [<base_path>/.recovered/]."
    Counter;
  (* #9786: auth layer rejects a request whose bearer token resolves
     to a credential owner different from the requested agent. *)
  add metric_auth_bearer_token_mismatch
    "Total Auth rejects where bearer token owner does not match the \
     requested agent_name (labels: expected_agent, actual_agent). Rate \
     advancing after a server restart indicates shared credential state \
     (connection pool / process fork) across agent identities."
    Counter;
  add metric_auth_strict_unknown_tool_denials
    "Total strict Auth rejects for unknown external tools \
     (labels: agent_name, tool_class=empty|external). This catches \
     fleet-wide tool dispatch regressions without using raw tool names \
     as metric labels."
    Counter;
  add metric_auth_credential_token_duplicate
    "Total boot-time credential token duplicate groups detected \
     (labels: token_hash_prefix). Any non-zero value means credential tokens \
     must be rotated."
    Counter;
  add metric_auth_credential_token_rotated
    "Total credentials automatically rotated out of a shared bearer-token \
     group (labels: token_hash_prefix, scope). Any positive value means \
     boot-time prevention repaired ambiguous credential state."
    Counter;
  add metric_telemetry_coverage_gap
    "Total telemetry coverage gaps recorded before append to the durable \
     coverage-gap store. Labels: source, producer, dashboard_surface, \
     stale_reason. Any positive rate means a telemetry lane is missing, \
     stale, or failed to append and dashboards should mark the source \
     coverage_gap."
    Counter;
  add metric_auth_credential_ambiguous_lookup
    "Total runtime credential lookups where N>=2 credentials share the \
     same token hash. Labels: first_match (the agent_name that List.find \
     routed to). Distinguishes \"audit warning, no traffic\" from \
     \"duplicate token actively serving the wrong agent\"."
    Counter;
  add metric_silent_auth_token_resolve_error
    "Total times mcp_server_eio_execute fell back to the requester-supplied \
     agent_name because Auth.resolve_agent_from_token returned an Error. \
     Labels: error_kind (token_mismatch | token_expired | other), \
     agent (the alias the request kept). Non-zero rate means token-based \
     identity rewrite is silently disabled in production."
    Counter;
  add metric_silent_dashboard_actor_fallback
    "Total times Server_auth.dashboard_actor_for_request resolved no agent \
     from the bearer token (Ok None / Error _) and fell back to \
     request_actor_hint. Labels: outcome (none | error), err_kind on error \
     paths. Counter exposes the path that masks identity drift in the HTTP \
     transport."
    Counter;
  add metric_auth_strict_would_reject
    "Phase A F2 (2026-04-27): every silent_auth_token_resolve_error fall-through \
     in mcp_server_eio_execute also increments this counter so operators can \
     measure how many of those would-be-rejections happen under each \
     MASC_AUTH_STRICT mode before Phase B PR-2 promotes Strict to a typed \
     reject. Labels: mode (off | dry_run | strict), error_kind, agent."
    Counter;
  add metric_empty_tool_universe_observed
    "Phase A F3 (2026-04-28): increments every time the keeper turn enters \
     the [Keeper_tool_surface_empty] blocker branch in keeper_agent_run \
     (i.e. tool_gate_requested && all_allowed = []). Pre-fix the blocker \
     fired silently with no operator-visible counter; this surfaces the \
     volume so Phase B PR-4 can promote it to a typed terminal state with \
     LLM-visible feedback. Labels: keeper_name, turn_lane (text_only \
     | tool_optional | tool_required | retry | tool_disabled), \
     fallback_used (true | false)."
    Counter;
  add metric_coord_join_normalize_outcome
    "Total Coord.join identity normalizations by Keeper_identity.normalize_all_names \
     (RFC P3-a). Labels: outcome (ok | empty_input | persona_not_found | \
     credential_missing | name_ambiguous | ephemeral_suffix_rejected). \
     Non-ok outcomes reject masc_join at the fail-closed identity gate; pair \
     with masc_silent_auth_token_resolve_error_total for auth/name drift \
     diagnosis."
    Counter;
  (* Transport metrics — registered here so transport_metrics.ml can use
     module constants instead of string literals. *)
  add metric_sse_sessions "Active SSE sessions by kind" Gauge;
  register_histogram ~name:metric_sse_broadcast_duration
    ~help:"Time to fan-out a broadcast to all SSE clients" ();
  add metric_sse_broadcast_events "Total SSE broadcast events emitted" Counter;
  add metric_sse_broadcast_failures
    "SSE broadcast deliveries that failed (stream full or enqueue exception). \
     Labelled by target so the failure rate can be compared against \
     masc_sse_broadcast_events_total per target."
    Counter;
  add metric_sse_external_subscriber_callback_failures
    "External SSE subscriber callback exceptions (e.g. gRPC bridge \
     stream errors).  A non-zero rate indicates that a downstream \
     consumer is failing to accept events even though the SSE fanout \
     considers the broadcast successful."
    Counter;
  add metric_oas_sse_relay_drop_marker_failures
    "OAS relay drop-marker broadcasts that themselves failed to emit. \
     The drop marker is the operator-visible signal that an OAS event \
     was dropped after exhausting retries; if the drop marker also \
     fails to broadcast, operators are blind to the drop entirely. \
     Distinct from masc_sse_broadcast_failures_total because the drop \
     marker is the recovery path's last resort, not a normal broadcast."
    Counter;
  add metric_sse_stream_queue_depth
    "Per-session SSE event stream queue depth" Gauge;
  add metric_sse_queue_depth_avg
    "Average SSE event queue depth across live sessions" Gauge;
  add metric_sse_queue_depth_max
    "Maximum SSE event queue depth across live sessions" Gauge;
  add metric_sse_external_subscribers
    "Active non-SSE subscribers bridged from the SSE fanout path" Gauge;

  add metric_keeper_turn_livelock_blocks
    "Total livelock-block events where keeper found a turn already in-progress      during unified_turn start. Labels: keeper." Counter;
  add metric_keeper_turn_timeout_committed
    "Total wall-clock timeout events after tools were committed but before      response completed. Labels: keeper." Counter;
  add metric_keeper_turn_error_after_tools
    "Total errors after tool calls were committed in unified_turn.      Labels: keeper." Counter;
  add metric_keeper_cascade_sync_failures
    "Total failures to sync cascade state during turn pause/rejection.      Labels: keeper, site." Counter;
  add metric_keeper_thinking_persist_failures
    "Total failures persisting thinking content to disk. Labels: keeper." Counter;
  add metric_keeper_checkpoint_failures
    "Total checkpoint save/restore failures. Labels: keeper, operation." Counter;
  add metric_keeper_memory_write_failures
    "Total failures writing keeper memory to disk. Labels: keeper." Counter;
  add metric_keeper_write_meta_cycle_failures
    "Total CAS-race or write failures in write_meta during turn cycle.      Labels: keeper." Counter;
  add metric_keeper_alert_persist_failures
    "Total failures persisting alert notifications. Labels: keeper." Counter;
  add metric_keeper_metrics_sse_failures
    "Total failures pushing metrics via SSE to dashboard. Labels: keeper." Counter;
  add metric_keeper_dispatch_event_failures
    "Total failures dispatching state events to keeper event bus.      Labels: keeper, event." Counter;
  add metric_keeper_session_cleanup_failures
    "Total failures cleaning up keeper session directories on shutdown." Counter;
  add metric_keeper_chat_store_failures
    "Total failures in keeper chat store append/load operations.      Labels: operation." Counter;
  add metric_keeper_observation_query_failures
    "Total failures in world observation queries (backlog, agents, board).      Labels: operation." Counter;
  add metric_keeper_stale_termination_total
    "Total stale watchdog terminations (all classes). Labels: keeper." Counter;
  add metric_keeper_stale_termination_by_class
    "Total stale watchdog terminations broken down by kill class      (idle_turn | in_turn_hung | noop_failure_loop). Labels: keeper, class." Counter;
  add metric_keeper_oas_timeout_budget_watchdog_termination
    "Total watchdog terminations preserving unresolved oas_timeout_budget      failure reason. Labels: keeper." Counter;
  add metric_keeper_stale_termination_threshold_breached
    "Total stale termination threshold breaches triggering auto-pause.      Labels: keeper." Counter;
  add metric_keeper_stale_termination_batch
    "Total fleet-wide batch termination events (multiple keepers terminated      within the batch window)." Counter;
  add metric_keeper_stale_broadcast_emit_failures
    "Total failures emitting stale keeper broadcast events. Labels: keeper." Counter;
  add metric_keeper_tool_use_failure
    "Total keeper tool use failures during OAS hooks. Labels: keeper, tool." Counter;
  add metric_after_turn_response_model_empty
    "After-turn response model resolution returned empty string." Counter;
  add metric_after_turn_response_model_alias
    "After-turn response model matched a known alias." Counter;
  add metric_pricing_catalog_miss
    "Pricing catalog lookups that missed. Labels: model." Counter;
  (* metric_cost_emit_zero_source registered in keeper_hooks_oas.ml with the
     authoritative help text and `source` label description. Re-registering
     here would be silently ignored (add is no-op when name exists) and risks
     diverging help text across edits. *)
  add metric_cost_ledger_status
    "Cost ledger status transitions per provider/status/reason combination. \
     Labels: provider, status, reason." Counter;
  (* metric_keeper_turn_gate_rejected_terminal registered in keeper_guards.ml
     with help text and labels keeper, tool, reason, decision.
     metric_keeper_receipt_unmapped_disposition registered in
     keeper_execution_receipt.ml without labels (intentional). Avoid
     re-registering here so the authoritative help/labels stay single-sourced. *)
  add metric_keeper_bash_network_upgrade
    "Bash shell network upgrade events. Labels: keeper, detected_tool." Counter;
  add metric_keeper_bash_local_execution
    "Bash shell local execution events. Labels: keeper, reason." Counter;
  add metric_keeper_docker_runtime_discarded
    "Docker shell runtime output discarded. Labels: keeper, reason." Counter;
  add metric_keeper_proactive_skip
    "Proactive turn skipped due to heartbeat snapshot conditions. Labels: keeper, reason." Counter;
  add metric_keeper_stay_silent_loop_detected
    "Stay-silent loop detector triggered. Labels: keeper." Counter;
  add metric_keeper_usage_trust
    "Keeper usage trust level. Labels: keeper, trust." Counter;
  add metric_keeper_usage_anomaly_reason
    "Keeper usage anomaly reason. Labels: keeper, reason." Counter;
  add metric_keeper_config_env_parse_failures
    "Config env var parse failures (non-integer values). Labels: var." Counter;
  add metric_keeper_post_turn_wirein_failures
    "Post-turn wire-in failures (autonomous, tool_emission_drain, multimodal, resilience). Labels: keeper, phase." Counter;
  (* metric_keeper_meta_read_failures registered earlier in init() with
     "labeled by keeper and site" — `add` is no-op when the name exists,
     so re-registering with a divergent help/label description here was
     silently dropped. Single registration kept. *)
  add metric_keeper_recurring_failures
    "Recurring task execution/dispatch failures. Labels: task, phase." Counter;
  add metric_keeper_turn_cleanup_failures
    "Turn cleanup failures (unsubscribe event_bus, mark_turn_finished). Labels: keeper, site." Counter;
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
  (* PR-0.2.A: generic cache hit/miss counters.  Labels: cache=eio|dashboard.
     [eio] tracks Cache_eio.get; [dashboard] tracks Dashboard_cache.get_or_compute.
     Per-label series are auto-created on first inc_counter call. *)
  add metric_cache_hits_total
    "Cache lookup hits. Labels: cache=eio|dashboard. \
     hit_ratio = hits / (hits + misses) per cache label."
    Counter;
  add metric_cache_misses_total
    "Cache lookup misses (compute required). Labels: cache=eio|dashboard."
    Counter;
  register_histogram ~name:metric_ws_client_buffered_bytes
    ~help:"Dashboard client WebSocket.bufferedAmount reported on each ack" ();
  add metric_ws_client_acks
    "Total dashboard/ack notifications received from WS clients"
    Counter;
  add metric_ws_throttled_deliveries
    "WS dashboard deliveries skipped because the client's last reported \
     bufferedAmount exceeded MASC_WS_CLIENT_BUFFER_LIMIT_BYTES"
    Counter;
  add metric_ws_slice_fanout_skipped
    "WS sessions skipped during slice-scoped fanout because their route \
     does not subscribe to the event's slice (gated by \
     MASC_WS_SLICE_INDEX_ENABLED, RFC #10119 Phase 2)"
    Counter;
  add metric_ws_bytes_sent
    "Bytes written to WebSocket clients (frame payload only, includes \
     dashboard deltas and raw SSE forwards). Capacity-planning input \
     for bandwidth-burst response."
    Counter;
  add metric_grpc_bytes_sent
    "Bytes serialised into gRPC Subscribe stream events delivered to \
     subscribers. Same purpose as masc_ws_bytes_sent_total but for the \
     gRPC transport."
    Counter;
  add metric_ws_delta_built
    "Per-session dashboard deltas constructed (one Yojson.Safe.t \
     allocation + jsonrpc_notification wrap per delta). Divide by \
     broadcast count to estimate fanout amplification."
    Counter;
  register_histogram ~name:metric_ws_message_bytes
    ~help:"WebSocket message payload size in bytes (per-frame, wire \
           boundary). Labelled by direction so send vs recv \
           distributions can be compared independently."
    ~labels:[("direction", "send")] ();
  register_histogram ~name:metric_ws_message_bytes
    ~help:"WebSocket message payload size in bytes (per-frame, wire \
           boundary). Labelled by direction so send vs recv \
           distributions can be compared independently."
    ~labels:[("direction", "recv")] ();
  add metric_grpc_backlog_replay_lines_scanned
    "Lines walked while replaying .masc/backlog.jsonl on a gRPC \
     Subscribe RPC (every line, including those filtered by \
     since_seq). Use with backlog file size to estimate disk read \
     cost amplification under a Subscribe burst."
    Counter;
  add metric_grpc_backlog_replay_events_replayed
    "Backlog events actually delivered (post-since_seq filter) on \
     gRPC Subscribe. Subset of grpc_events_delivered; the difference \
     between scanned-lines and replayed-events isolates wasted \
     scan cost."
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
      Printf.bprintf buf "# HELP %s %s\n" name m.help;
      (match m.metric_type with
       | Histogram ->
         (* No bucket distribution is tracked, so emit as summary
            (sum + count) which is the closest valid Prometheus type. *)
         Printf.bprintf buf "# TYPE %s summary\n" name;
         List.iter (fun (metric : metric) ->
           let ls = labels_to_string metric.labels in
           Buffer.add_string buf
             (Printf.sprintf "%s_sum%s %g\n" name ls metric.value);
           let count_key = metric_key (name ^ "_count") metric.labels in
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
           Printf.bprintf buf "%s%s %g\n"
             metric.name (labels_to_string metric.labels) metric.value
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
