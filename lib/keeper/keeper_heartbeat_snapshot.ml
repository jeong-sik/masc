(* keeper_heartbeat_snapshot — heartbeat snapshot write, event dispatch,
   stage timing metrics.

   Extracted from keeper_keepalive.ml. The [write_heartbeat_snapshot]
   function is the primary heartbeat status persistence path, reading
   context from checkpoint, computing continuity/guard metrics, and
   appending to the metrics ledger. *)

open Keeper_types
open Keeper_memory
open Keeper_execution

(* #10008 fm3: canonical metric name for proactive-scheduler skip
   reasons.  Labels: [("keeper", <name>); ("reason", <skip_reason>)].
   [reason] is derived from
   [Keeper_world_observation.verdict_reasons_to_strings], which
   produces one of {keeper_paused, approval_pending,
   scheduled_autonomous_disabled, provider_cooldown_pending,
   idle_gate_pending, cooldown_pending, no_signal}. *)
let proactive_skip_reason_metric = Prometheus.metric_keeper_proactive_skip

let keepalive_interval_sec () =
  Runtime_params.get Governance_registry.keeper_keepalive_interval_sec
;;

(* ── Heartbeat history fallback read limits ── *)
let max_history_read_bytes = 256 * 1024
let max_history_read_lines = 200

let status_tick_usage_json () =
  `Assoc
    [
      ("input_tokens", `Int 0);
      ("output_tokens", `Int 0);
      ("cache_creation_tokens", `Int 0);
      ("cache_read_tokens", `Int 0);
      ("total_tokens", `Int 0);
    ]

let max_consecutive_heartbeat_failures () =
  Runtime_params.get Governance_registry.keeper_max_hb_failures
;;

let max_consecutive_turn_failures () =
  Runtime_params.get Governance_registry.keeper_max_turn_failures
;;

let write_heartbeat_snapshot
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(now_ts : float)
      ~(consecutive_hb_failures : int)
      ~(timing_ring : Keeper_keepalive_signal.stage_timing array)
      ~(timing_filled : int)
  : unit
  =
  let metrics_store = keeper_metrics_store ctx.config meta_current.name in
  let cascade_models =
    Cascade_runtime.models_of_cascade_name
      (Keeper_cascade_profile.Runtime_name meta_current.cascade_name)
  in
  let max_cascade_context =
    let resolution =
      Keeper_exec_context.resolve_max_context_resolution
        ~requested_override:meta_current.max_context_override
        cascade_models
    in
    resolution.effective_budget
  in
  let base_dir = session_base_dir ctx.config in
  ignore (Keeper_fs.ensure_dir (Filename.concat base_dir (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)));
  let _session, ctx_opt =
    load_context_from_checkpoint
      ~max_checkpoint_messages:meta_current.compaction.max_checkpoint_messages
      ~trace_id:(Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
      ~primary_model_max_tokens:max_cascade_context
      ~base_dir
  in
  (* Fallback: when OAS checkpoint is absent (e.g. after server restart
     mid-turn), load messages from history.jsonl to recover continuity.
     This prevents the "orphan user" problem where interrupted turns
     leave user-only entries and continuity_summary stays empty forever.
     Read is bounded to avoid large allocations during heartbeats. *)
  let messages_for_continuity = match ctx_opt with
    | Some c -> Keeper_exec_context.messages_of_context c
    | None ->
      let history_path =
        Keeper_types.keeper_history_path ctx.config
          (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
      in
      let internal_history_path =
        Keeper_types.keeper_internal_history_path ctx.config
          (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
      in
      (let parse_errors = ref 0 in
       let messages =
         try
           [ history_path; internal_history_path ]
           |> List.concat_map (fun path ->
                read_file_tail_lines path
                  ~max_bytes:max_history_read_bytes
                  ~max_lines:max_history_read_lines)
           |> List.filter_map (fun line ->
             try
               let json = Yojson.Safe.from_string line in
               let source =
                 Safe_ops.json_string ~default:"" "source" json |> String.trim
               in
               let content =
                 Safe_ops.json_string ~default:"" "content" json |> String.trim
               in
               ignore content;
               if Keeper_types.is_prompt_history_source source then None
               else Some (Keeper_context_core.message_of_json json)
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | _exn ->
               incr parse_errors;
               None)
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Keeper.warn "write_heartbeat_snapshot: history.jsonl load error (%s): %s"
             meta_current.name (Printexc.to_string exn);
           []
       in
       if !parse_errors > 0 then
         Log.Keeper.warn
           "write_heartbeat_snapshot: failed to parse %d message(s) from history logs for keeper=%s trace_id=%s path=%s"
           !parse_errors meta_current.name
           (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
           history_path;
       messages)
  in
  let c_messages = messages_for_continuity in
  let latest_user_message =
    latest_message_content_by_role ~role:Agent_sdk.Types.User c_messages
  in
  let latest_assistant_message =
    latest_message_content_by_role ~role:Agent_sdk.Types.Assistant c_messages
    in
    let continuity_snapshot = latest_state_snapshot_from_messages c_messages in
    let continuity_summary =
      match continuity_snapshot with
      | Some s -> keeper_state_snapshot_to_summary_text s
      | None ->
        continuity_fallback_summary_text
          ~continuity_summary:meta_current.continuity_summary
          ~last_continuity_update_ts:meta_current.runtime.last_continuity_update_ts
    in
    let repetition_risk =
      repetition_risk_score ~messages:c_messages ~candidate_reply:None
    in
    let goal_alignment =
      goal_alignment_score
        ~meta:meta_current
        ~user_message:latest_user_message
        ~assistant_reply:latest_assistant_message
    in
    let response_alignment =
      match latest_user_message, latest_assistant_message with
      | Some user_message, Some assistant_message ->
        jaccard_similarity user_message assistant_message
      | _ ->
        (* Unmeasurable (status_tick, heartbeat, empty reply): use the
           sentinel [1.0] so the plan gate [<= 0.100] and guardrail gate
           [<= floor] do NOT fire. [0.0] was a permissive default that
           conflated "no alignment measurable" with "no alignment at
           all", triggering auto_plan on every status_tick (#10012).
           CLAUDE.md anti-pattern #2: Unknown → Permissive Default. *)
        1.0
    in
    (* status_tick / heartbeat turns lack a user/assistant pair, so the 0.0
       fallbacks above are sentinels, not measurements. Mark the snapshot
       non-measurable and let Keeper_guard fail-closed on similarity gates. *)
    let similarity_measurable =
      Option.is_some latest_user_message
      && Option.is_some latest_assistant_message
    in
    let context_ratio_v = match ctx_opt with
      | Some c -> Keeper_exec_context.context_ratio c
      | None -> 0.0
    in
    let message_count_v = match ctx_opt with
      | Some c -> Keeper_exec_context.message_count c
      | None -> List.length c_messages
    in
    let token_count_v = match ctx_opt with
      | Some c -> Keeper_exec_context.token_count c
      | None -> 0
    in
    let turn_fail_count =
      Keeper_registry.get_turn_failures
        ~base_path:ctx.config.base_path
        meta_current.name
    in
    let since_last_compaction_sec =
      if meta_current.runtime.compaction_rt.last_ts <= 0.0
      then now_ts
      else max 0.0 (now_ts -. meta_current.runtime.compaction_rt.last_ts)
    in
    let since_last_handoff_sec =
      if meta_current.runtime.last_handoff_ts <= 0.0
      then now_ts
      else max 0.0 (now_ts -. meta_current.runtime.last_handoff_ts)
    in
    (* RFC-0002: build measurement_snapshot via pure capture function.
       Timing/failure inputs now come from the live keepalive loop and
       registry so audit reflects the real runtime decision surface. *)
    let thresholds : Keeper_measurement.threshold_params =
      { compaction_ratio_gate = meta_current.compaction.ratio_gate
      ; compaction_message_gate = meta_current.compaction.message_gate
      ; compaction_token_gate = meta_current.compaction.token_gate
      ; compaction_cooldown_sec = meta_current.compaction.cooldown_sec
      ; handoff_threshold = meta_current.handoff_threshold
      ; handoff_cooldown_sec = meta_current.handoff_cooldown_sec
      ; auto_handoff_enabled = meta_current.auto_handoff
      ; reflect_repetition_threshold =
          Keeper_config.keeper_rule_reflect_repetition_threshold ()
      ; plan_goal_alignment_threshold =
          Keeper_config.keeper_rule_plan_goal_alignment_threshold ()
      ; plan_response_alignment_threshold =
          Keeper_config.keeper_rule_plan_response_alignment_threshold ()
      ; guardrail_repetition_threshold =
          Keeper_config.keeper_rule_guardrail_repetition_threshold ()
      ; guardrail_goal_alignment_threshold =
          Keeper_config.keeper_rule_guardrail_goal_alignment_threshold ()
      ; guardrail_response_alignment_threshold =
          Keeper_config.keeper_rule_guardrail_response_alignment_threshold ()
      ; guardrail_context_threshold =
          Keeper_config.keeper_rule_guardrail_context_threshold ()
      ; max_consecutive_hb_failures = max_consecutive_heartbeat_failures ()
      ; max_consecutive_turn_failures = max_consecutive_turn_failures ()
      ; model_ratio_multiplier = 1.0
      ; model_handoff_multiplier = 1.0
      }
    in
    let measurement =
      Keeper_measurement.capture
        ~snapshot_id:
          (Printf.sprintf "msnap-%s-%Ld"
             meta_current.name
             (Int64.of_float (now_ts *. 1000.0)))
        ~keeper_name:meta_current.name
        ~generation:meta_current.runtime.generation
        ~timestamp:now_ts
        ~thresholds
        ~context_ratio:context_ratio_v
        ~message_count:message_count_v
        ~token_count:token_count_v
        ~max_tokens:
          (match ctx_opt with
           | Some c -> Keeper_context_core.max_tokens_of_context c
           | None -> max_cascade_context)
        ~repetition_risk
        ~goal_alignment
        ~response_alignment
        ~similarity_measurable
        ~now_ts
        ~idle_seconds:0
        ~since_last_compaction_sec
        ~since_last_handoff_sec
        ~proactive_warmup_elapsed:false
        ~consecutive_hb_failures
        ~consecutive_turn_failures:turn_fail_count
        ()
    in
    let guard_events = Keeper_guard.evaluate measurement in
    let auto_rules =
      keeper_auto_rule_eval_of_measurement ~events:guard_events measurement
    in
    let selected_guard_event = Keeper_guard.prioritized_event guard_events in
    (* RFC-0002: dispatch Context_measured event through state machine *)
    let () =
      Keeper_keepalive_signal.dispatch_keepalive_event_with_audit
        ~ctx
        ~keeper_name:meta_current.name
        ~snapshot:measurement
        ~events_fired:guard_events
        ~selected_event:selected_guard_event
        (Keeper_state_machine.Context_measured {
          context_ratio = context_ratio_v;
          message_count = message_count_v;
          token_count = token_count_v;
          auto_rules = {
            Keeper_state_machine.reflect = auto_rules.reflect;
            plan = auto_rules.plan;
            compact = auto_rules.compact;
            handoff = auto_rules.handoff;
            guardrail_stop = auto_rules.guardrail_stop;
            guardrail_reason = auto_rules.guardrail_reason;
            goal_drift = auto_rules.goal_drift;
          };
        })
    in
    (* B1: Guard → Thompson bridge. When guardrail fires, record a negative
       signal in Thompson β. Penalty cap 1/cycle is naturally enforced: guard
       evaluates once per heartbeat call. Gated by MASC_DECISION_LAYER_LEVEL >= 2. *)
    if auto_rules.guardrail_stop
       && Keeper_decision_audit.decision_layer_level () >= 2
    then
      (try Thompson_sampling.record_guard_penalty ~agent_name:meta_current.name
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Keeper.warn "guard→thompson penalty failed for %s: %s"
           meta_current.name (Printexc.to_string exn));
    let snapshot =
      `Assoc
        [ "ts", `String (now_iso ())
        ; "ts_unix", `Float now_ts
        ; "channel", `String "heartbeat"
        ; "name", `String meta_current.name
        ; "agent_name", `String meta_current.agent_name
        ; "trace_id", `String (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
        ; "generation", `Int meta_current.runtime.generation
        ; (* #10018 follow-up: [model_used] is also snapshot-stale.
             last_model_used is the *previous turn's* provider label;
             emitting it on every heartbeat made
             per-provider latency histograms and dashboards show
             ghost provider names long after the binary that wrote
             them was rebuilt (observed qa-king / nick0cave stuck on
             "deterministic_required_tool_fallback" across
             post-#9967 rebuild).  Emit empty string here so
             downstream per-provider aggregation ignores heartbeat
             records.  `last_model_used_label` on the keeper state
             JSON still reflects the last real turn for dashboard
             snapshot panels. *)
          "model_used", `String ""
        ; (* #10018: status_tick is a snapshot, not an LLM-call event.
             Emitting [runtime.usage.last_*_tokens] and [last_latency_ms]
             caused the last turn's per-turn values to be repeat-emitted
             on every heartbeat — observed analyst heartbeats 5 min
             apart both reported [input=273325, output=8067,
             total=281392, latency_ms=191894] while no LLM call ran.
             Downstream daily token aggregates and p50 latency were
             inflated by ~heartbeat-count per turn. Same "snapshot vs
             event" boundary fix as #9950 for compaction fields.
             [total_cost_usd] is a running total and remains emitted. *)
          "usage", status_tick_usage_json ()
        ; "latency_ms", `Int 0
        ; "cost_usd", `Float meta_current.runtime.usage.total_cost_usd
        ; "context_ratio", `Float context_ratio_v
        ; "context_tokens", `Int token_count_v
        ; "context_max",
          `Int
            (match ctx_opt with
             | Some c -> Keeper_context_core.max_tokens_of_context c
             | None -> max_cascade_context)
        ; "message_count", `Int message_count_v
        ; ( "continuity_state"
          , match continuity_snapshot with
            | None -> `Null
            | Some s -> keeper_state_snapshot_to_json s )
        ; "continuity_summary", `String continuity_summary
        ; "compacted", `Bool false
        ; (* #9943: status_tick is a snapshot, not a compaction
             event. Emitting [before = after = token_count_v]
             caused 956/972 (98.4%) of daily metric entries to
             look like compaction attempts with zero savings —
             a false signal that drowned actual compactions.
             Zero marks the record as "not a compaction event";
             the dashboard already skips records with
             compacted=false, but analysts running ad-hoc jq over
             the ledger no longer mistake status_tick for a
             failed compaction. *)
          "compaction_before_tokens", `Int 0
        ; "compaction_after_tokens", `Int 0
        ; "work_kind", `String "status_tick"
        ; "tool_call_count", `Int 0
        ; "tools_used", `List []
        ; "snapshot_source", `String "keeper_context_status"
        ; "memory_check", memory_check_default_json ()
        ; "auto_rules", keeper_auto_rule_eval_to_json auto_rules
        ; "reflection", keeper_reflection_payload_of_auto_rules auto_rules
        ; "auto_reflect", `Bool auto_rules.reflect
        ; "auto_plan", `Bool auto_rules.plan
        ; "auto_compact", `Bool auto_rules.compact
        ; "auto_handoff", `Bool auto_rules.handoff
        ; "repetition_risk", `Float repetition_risk
        ; "goal_alignment", `Float goal_alignment
        ; "response_alignment", `Float response_alignment
        ; "goal_drift", `Float auto_rules.goal_drift
        ; "guardrail_stop", `Bool auto_rules.guardrail_stop
        ; ( "guardrail_stop_reason"
          , match auto_rules.guardrail_reason with
            | Some reason -> `String reason
            | None -> `Null )
        ; "handoff", `Assoc [ "performed", `Bool false ]
        ; "stage_timing", Keeper_keepalive_signal.stage_timing_to_json ~ring:timing_ring ~count:timing_filled
        ]
    in
    Dated_jsonl.append metrics_store snapshot;
    (try
       let json =
         `Assoc
           [ "type", `String "keeper_heartbeat"
           ; "name", `String meta_current.name
           ; "generation", `Int meta_current.runtime.generation
           ; "context_ratio", `Float context_ratio_v
           ; "ts_unix", `Float now_ts
           ]
       in
       Sse.broadcast json;
       Sse.broadcast_presence json
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.error "heartbeat SSE broadcast failed: %s" (Printexc.to_string exn));
    (match Keeper_event_bus.get () with
     | Some bus ->
       Oas_events.publish_keeper_snapshot
         bus
         ~keeper_name:meta_current.name
         ~generation:meta_current.runtime.generation
         ~context_ratio:context_ratio_v
         ~message_count:message_count_v
     | None -> ());
    (try
       Keeper_registry.flush_tool_usage ~base_path:ctx.config.base_path meta_current.name
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.warn "keeper:%s flush_tool_usage failed: %s"
         meta_current.name (Printexc.to_string exn))
;;
