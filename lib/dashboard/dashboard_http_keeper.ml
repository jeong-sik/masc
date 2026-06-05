(** Dashboard HTTP keeper — keepers_dashboard_json rendering.

    Extracted from server_dashboard_http.ml. Contains the keeper dashboard
    rendering: per-keeper metrics series, 24h buckets, conversation history,
    memory bank, and diagnostic summaries. *)


open Dashboard_http_helpers
open Keeper_status_bridge

include Dashboard_http_keeper_detail

(** Health constants + compute_health_score + live runtime-id resolver moved
    to Dashboard_http_keeper_types (intra-library file split, 2026-05-16). *)
include Dashboard_http_keeper_types
module Outcomes = Dashboard_http_keeper_outcomes
module Trust = Dashboard_http_keeper_trust

let compute_outcomes_rollup = Outcomes.compute_outcomes_rollup

(** Estimate seconds until Dead based on current restart_count and
    exponential backoff schedule. Returns None if already dead or
    restart_count >= max_restarts. *)
(* estimate_dead_eta_sec / prompt_block_json / tokens_per_sec_json /
   last_latency_ms_json moved to Dashboard_http_keeper_types
   (intra-library file split, 2026-05-16). *)

let keeper_trust_json = Trust.keeper_trust_json

(* execution_trust_source / _producer / _dashboard_surface / _freshness_slo_s
   moved to Dashboard_http_keeper_types (intra-library file split,
   2026-05-16). *)

(* execution_receipt path/diagnostic helpers extracted to
   [Dashboard_http_keeper_execution_receipt] (godfile decomp). *)
let execution_receipt_store_pattern = Dashboard_http_keeper_execution_receipt.execution_receipt_store_pattern
let count_execution_receipt_entries = Dashboard_http_keeper_execution_receipt.count_execution_receipt_entries
let execution_receipt_coverage_gaps = Dashboard_http_keeper_execution_receipt.execution_receipt_coverage_gaps

let keeper_names (config : Workspace.config) =
  Keeper_meta_store.keeper_names config

let keeper_count (config : Workspace.config) : int =
  List.length (keeper_names config)

let running_keeper_count (config : Workspace.config) : int =
  keeper_names config
  |> List.fold_left
       (fun count name ->
         match Keeper_meta_store.read_meta config name with
         | Ok (Some meta) when runtime_keepalive_running config meta -> count + 1
         | _ -> count)
       0

let keepers_dashboard_json ?(compact = false) (config : Workspace.config) : Yojson.Safe.t =
  let include_goals = true in
  let history_fragment_filter_enabled =
    bool_default_true_of_env "MASC_KEEPER_HISTORY_FRAGMENT_FILTER"
  in
  let series_points = 120 in
  let names = keeper_names config in
  let now_ts = Time_compat.now () in
  let max_restarts =
    Runtime_params.get Governance_registry.keeper_supervisor_max_restarts
  in
  let keepers_dir =
    Workspace.keepers_runtime_dir config
  in
  let shared_sp_events =
    try
      Keeper_crash_persistence.recent_sp_events
        ~keepers_dir ~max_entries:20
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
        Log.Dashboard.warn
          "keeper dashboard recent_sp_events failed: %s"
          (Printexc.to_string exn);
        []
  in
  let accountability_summary =
    if compact || Keeper_decision_audit.decision_layer_level () < 3 then
      (fun ~keeper_name ~agent_name ->
        Keeper_status_metrics.accountability_summary_json config
          ~keeper_name ~agent_name)
    else
      Keeper_status_metrics.accountability_summary_lookup config
  in
  (* Parallel keeper I/O: each keeper's metadata + metrics reads run concurrently.
     Results are collected into a shared ref array, then filter_map'd. *)
  let results = Array.make (List.length names) None in
  Eio.Fiber.all
    (List.mapi (fun idx name -> fun () ->
      results.(idx) <- (
      match Keeper_meta_store.read_meta config name with
      | Error _ | Ok None -> None
      | Ok (Some (m : Keeper_meta_contract.keeper_meta)) ->
          let agent = Keeper_status_runtime.parse_agent_status config ~agent_name:m.agent_name in

          let created_ts =
            Workspace_resilience.Time.parse_iso8601_opt m.created_at
            |> Option.value ~default:0.0
          in
          let keeper_age_s = if created_ts <= 0.0 then 0.0 else now_ts -. created_ts in
          let last_turn_ago_s = if m.runtime.usage.last_turn_ts <= 0.0 then 0.0 else now_ts -. m.runtime.usage.last_turn_ts in
          let last_handoff_ago_s =
            if m.runtime.last_handoff_ts <= 0.0 then 0.0 else now_ts -. m.runtime.last_handoff_ts
          in
          let last_compaction_ago_s =
            if m.runtime.compaction_rt.last_ts <= 0.0 then 0.0 else now_ts -. m.runtime.compaction_rt.last_ts
          in
          let last_proactive_ago_s =
            if m.runtime.proactive_rt.last_ts <= 0.0 then 0.0 else now_ts -. m.runtime.proactive_rt.last_ts
          in
          let last_visible_proactive_ago_s =
            if m.runtime.proactive_rt.last_visible_ts <= 0.0 then 0.0
            else now_ts -. m.runtime.proactive_rt.last_visible_ts
          in
          (* C-3 fix: compute last_activity from the most recent activity timestamp
             to avoid showing misleading staleness when agent is actually active *)
          let last_activity_ts =
            List.fold_left max 0.0
              [ m.runtime.usage.last_turn_ts; m.runtime.proactive_rt.last_ts; m.runtime.last_handoff_ts;
                m.runtime.compaction_rt.last_ts; created_ts ]
          in
          let last_activity_ago_s =
            if last_activity_ts <= 0.0 then 0.0 else now_ts -. last_activity_ts
          in
          let trace_history_count = List.length m.runtime.trace_history in
          (* RFC-0149 §3.3 — removed [_effective_runtime_id] zombie
             binding (commit f0075c3611, "domain-owned counter").  The
             bound name was unused; the line existed only to trigger
             [Runtime_metrics.on_resolve_live_fallback] through the
             silent-fallback path — exactly the workaround RFC-0149
             §3.3 sunsets.  No replacement needed: unresolved runtimes
             surface on the canonical JSON field via the Result-returning
             resolver at the other call site below. *)
          let primary_model = "" in
          let primary_model_norm = normalize_model_name primary_model in
          let last_compaction_saved_tokens =
            max 0 (m.runtime.compaction_rt.last_before_tokens - m.runtime.compaction_rt.last_after_tokens)
          in

          let metrics_store = Keeper_types_support.keeper_metrics_store config m.name in
          (* Cap metrics lines to avoid O(n) slowdown as keepers accumulate turns.
             series_points (120) suffices for the chart; 500 covers 24h summary.
             Previous value of 12000 caused 60K+ lines across 5 keepers. *)
          let metrics_cap = if compact then series_points else 500 in
          let metrics_window_max_bytes = if compact then 50000 else 200000 in
          let all_metrics_lines =
            let n = metrics_cap in
            let dated = Dated_jsonl.read_recent_lines metrics_store n in
            if dated <> [] then dated
            else
              let metrics_path = Keeper_types_support.keeper_metrics_path config m.name in
              Dashboard_http_helpers.keeper_tail_lines_or_empty ~site:"dashboard_keeper_metrics" metrics_path
                ~max_bytes:metrics_window_max_bytes ~max_lines:n
          in
          let (metrics_24h, metrics_24h_summary) =
            if compact then (`Null, `Null)
            else keeper_metrics_24h_json ~metrics_lines:all_metrics_lines ~now_ts
          in
          let metrics_lines = all_metrics_lines in
          let parsed_metrics =
            List.filter_map (fun line ->
              try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None
            ) metrics_lines
          in
          let last_metrics =
            List.find_opt metrics_row_has_context_snapshot
              (List.rev parsed_metrics)
          in
	          let (last_skill_primary, last_skill_secondary, last_skill_reason) =
	            let rec find_latest = function
	              | [] -> (None, [], None)
	              | j :: tl ->
	                  (match Safe_ops.json_string_opt "skill_primary" j with
	                   | Some primary when String.trim primary <> "" ->
	                       let secondary =
	                         match Json_util.assoc_member_opt "skill_secondary" j |> Option.value ~default:`Null with
	                         | `List xs ->
	                             xs
	                             |> List.filter_map (fun v ->
	                                    match v with
	                                    | `String s when String.trim s <> "" -> Some s
	                                    | _ -> None)
	                         | _ -> []
	                       in
	                       let reason = Safe_ops.json_string_opt "skill_reason" j in
	                       (Some primary, secondary, reason)
	                   | _ -> find_latest tl)
	            in
	            find_latest (List.rev parsed_metrics)
	          in


          let (metrics_series_items, metrics_window_summary, last_handoff_event, last_compaction_event) =
            compute_metrics_window
              ~parsed_metrics ~generation:m.runtime.generation ~compact ~series_points
              ~metrics_window_max_bytes ~primary_model_norm ~primary_model
          in
          let metrics_series = `List metrics_series_items in

          let provider_health_json = `Null in

          (* In compact mode (used by execution surface), skip heavy memory bank I/O.
             Full memory bank is only needed for individual keeper detail view. *)
          (* RFC-0149 §3.1 — route through the Result-returning resolver
             so a memory-bank IO fault surfaces a typed [unavailable]
             JSON shape that the dashboard frontend can render as a
             warning state, separate from "Ok summary with empty bank". *)
          let (memory_bank_json, memory_recent_note) =
            if compact then
              (`Assoc [("total_files", `Int 0); ("skipped", `Bool true)], None)
            else
              match
                Keeper_memory.read_keeper_memory_summary_result
                  config
                  ~name:m.name
                  ~max_bytes:120000
                  ~max_lines:200
                  ~recent_limit:4
              with
              | Ok summary ->
                let note = match summary.Keeper_memory.recent_notes with
                  | row :: _ -> Some row.Keeper_memory.text
                  | [] -> None
                in
                (Keeper_memory.memory_summary_to_json summary, note)
              | Error exn_class ->
                let label =
                  Keeper_memory_recall_exn_class.to_label exn_class
                in
                let note =
                  Some (Printf.sprintf "[memory unavailable: %s]" label)
                in
                let json =
                  `Assoc
                    [ ("total_files", `Int 0)
                    ; ("unavailable", `Bool true)
                    ; ("error_class", `String label)
                    ]
                in
                (json, note)
          in
          let history_path =
            Filename.concat
              (Filename.concat (Keeper_types_profile.session_base_dir config) (Keeper_id.Trace_id.to_string m.runtime.trace_id))
              "history.jsonl"
          in
          let ( conversation_tail,
                k2k_recent,
                k2k_mentions,
                conversation_raw_count,
                conversation_fragment_count,
                conversation_fragment_filtered_count ) =
            keeper_history_summary_json
              ~all_keeper_names:names
              ~keeper_name:m.name
              ~history_path
              ~filter_fragments:history_fragment_filter_enabled
          in
          let conversation_tail_count =
            match conversation_tail with
            | `List xs -> List.length xs
            | _ -> 0
          in
          let conversation_items =
            match conversation_tail with
            | `List xs -> xs
            | _ -> []
          in
          let recent_preview_for_role role_name =
            let role_name = String.lowercase_ascii role_name in
            conversation_items
            |> List.fold_left
                 (fun acc item ->
                   let role =
                     Safe_ops.json_string ~default:"" "role" item
                     |> String.lowercase_ascii
                     |> String.trim
                   in
                   if String.equal role role_name then
                     let preview =
                       Safe_ops.json_string ~default:"" "preview" item |> String.trim
                     in
                     if preview = "" then acc else Some preview
                   else
                     acc)
                 None
          in
          let k2k_count =
            match k2k_recent with
            | `List xs -> List.length xs
            | _ -> 0
          in
          let keepalive_running = runtime_keepalive_running config m in
          let registry_entry =
            Keeper_registry.get ~base_path:config.base_path m.name in
          let phase =
            match registry_entry with
            | Some entry -> Some (Keeper_state_machine.phase_to_string entry.phase)
            | None -> None
          in
          let conditions_json =
            match registry_entry with
            | Some entry ->
                Keeper_state_machine_json.conditions_to_json entry.conditions
            | None -> `Null
          in
          let sandbox_last_error =
            match registry_entry with
            | Some entry -> entry.last_error
            | None -> None
          in
          (* reconcile_status removed with manual_reconcile blocker system. *)
          let runtime_blocker_fields =
            runtime_blocker_fields_json config m
          in
          let attention_fields =
            attention_fields_json config m
          in
          let runtime_contract =
            Keeper_runtime_contract.runtime_observability_contract_json ~config m
          in
          let goal_progress =
            Option.value ~default:`Null (Json_util.assoc_member_opt "goal_progress" runtime_contract)
          in
          let blocked_task_count =
            Safe_ops.json_int "blocked_task_count" ~default:0 runtime_contract
          in
          let approval_policy_effective =
            Option.value ~default:`Null (Json_util.assoc_member_opt "approval_policy_effective" runtime_contract)
          in
          let sandbox_target =
            Safe_ops.json_string "sandbox_target" ~default:"unknown"
              runtime_contract
          in
          let supervisor_diagnostics, recent_crash_count =
            match registry_entry with
            | Some entry ->
                let crash_log =
                  List.map (fun (ts, reason) ->
                    `Assoc [("ts", `Float ts); ("reason", `String reason)]
                  ) entry.crash_log in
                let disk_crashes =
                  (try
                     Keeper_crash_persistence.recent_crashes
                       ~keepers_dir ~name:m.name ~max_entries:20
                   with
                   | Eio.Cancel.Cancelled _ as exn -> raise exn
                   | exn ->
                       Log.Dashboard.warn
                         "keeper dashboard recent_crashes failed for %s: %s"
                         m.name (Printexc.to_string exn);
                       []) in
                let combined_log = match disk_crashes with
                  | [] -> crash_log
                  | _ -> disk_crashes in
                let ctx_ratio =
                  match last_metrics with
                  | Some m -> Safe_ops.json_float "context_ratio" m
                  | None -> 0.0 in
                let health_score = compute_health_score
                  ~restart_count:entry.restart_count
                  ~max_restarts
                  ~recent_crash_count:(List.length combined_log)
                  ~is_dead:(Option.is_some entry.dead_since_ts)
                  ~context_ratio:ctx_ratio in
                (`Assoc [
                  ("restart_count", `Int entry.restart_count);
                  ("max_restarts", `Int max_restarts);
                  ("crash_log", `List combined_log);
                  ("last_failure_reason",
                    match entry.last_failure_reason with
                    | Some r -> `String (Keeper_registry.failure_reason_to_string r)
                    | None -> `Null);
                  ("dead_since", Json_util.float_opt_to_json entry.dead_since_ts);
                  ("sp_events", `List shared_sp_events);
                  ("health_score", `Int health_score);
                  ("dead_eta_sec",
                    Json_util.float_opt_to_json
                      (estimate_dead_eta_sec
                        ~restart_count:entry.restart_count ~max_restarts));
                ], List.length combined_log)
            | None ->
                (`Assoc [
                  ("restart_count", `Int 0);
                  ("max_restarts", `Int max_restarts);
                  ("crash_log", `List []);
                  ("last_failure_reason", `Null);
                  ("dead_since", `Null);
                  ("sp_events", `List []);
                  ("health_score", `Int 100);
                  ("dead_eta_sec", `Null);
                ], 0)
          in
          let outcomes_json =
            compute_outcomes_rollup
              ~keeper_name:m.name
              ~agent_name:m.agent_name
              ~recent_crash_count
              ~registry_entry
          in

          let context =
            match last_metrics with
            | Some metrics ->
                `Assoc [
                  ("source", `String "metrics");
                  ("context_ratio", `Float (Safe_ops.json_float "context_ratio" metrics));
                  ("context_tokens", `Int (Safe_ops.json_int "context_tokens" metrics));
                  ("context_max", `Int (Safe_ops.json_int "context_max" metrics));
                  ("message_count", `Int (Safe_ops.json_int "message_count" metrics));
                ]
            | None ->
                (let primary_max_context = 0 in
                     let base_dir = Keeper_types_profile.session_base_dir config in
                     let (_session, ctx_opt) =
                       Keeper_execution.load_context_from_checkpoint
                         ~max_checkpoint_messages:m.compaction.max_checkpoint_messages
                         ~trace_id:(Keeper_id.Trace_id.to_string m.runtime.trace_id)
                         ~primary_model_max_tokens:primary_max_context
                         ~base_dir
                     in
                     match ctx_opt with
                     | None -> `Assoc [("has_checkpoint", `Bool false)]
                     | Some c ->
                         `Assoc [
                           ("has_checkpoint", `Bool true);
                           ("source", `String "checkpoint");
                           ("context_ratio", `Float (Keeper_context_runtime.context_ratio c));
                           ("context_tokens", `Int (Keeper_context_runtime.token_count c));
                           ("context_max", `Int c.max_tokens);
                           ("message_count", `Int (Keeper_context_runtime.message_count c));
                         ])
          in
	          let context_source =
	            match context with
	            | `Assoc fields ->
	                (match List.assoc_opt "source" fields with
	                 | Some s -> s
	                 | None -> `Null)
	            | _ -> `Null
	          in
	          let summary =
	            let compact_ratio_gate = m.compaction.ratio_gate in
	            let compact_message_gate = m.compaction.message_gate in
	            let compact_token_gate = m.compaction.token_gate in
              let trust_json =
                keeper_trust_json ~include_receipt:(not compact) config m
              in
              let recent_tool_names =
                match metrics_window_summary with
                | `Assoc fields -> (
                    match List.assoc_opt "top_tools" fields with
                    | Some (`List items) ->
                        items
                        |> List.filter_map (fun item ->
                               let tool =
                                 Safe_ops.json_string ~default:"" "tool" item |> String.trim
                               in
                               if tool = "" then None else Some tool)
                    | _ -> [])
                | _ -> []
              in
              let diagnostic =
	                Keeper_status_runtime.keeper_diagnostic_json
	                  ~meta:m
	                  ~agent_status:agent
	                  ~keepalive_running
	                  ~history_items:conversation_items
	                  ~now_ts
	                |> Keeper_status_runtime.augment_keeper_diagnostic_json
	                     ~meta:m
	                     ~keepalive_running
	                     ~keepalive_started_at:(runtime_keepalive_started_at config m)
                     ~now_ts
              in
              (* C0: Trust Observatory — raw signals side-by-side, no synthesis.
                 Reputation (overall_score), Thompson (alpha/beta).
                 Gated by MASC_DECISION_LAYER_LEVEL >= 3. *)
              let trust_observatory =
                if compact
                   || Keeper_decision_audit.decision_layer_level () < 3
                then `Null
                else
                  let reputation =
                    (try
                       let rep = Reputation.compute_reputation config ~agent_name:m.agent_name in
                       Reputation.reputation_to_json rep
                     with
                     | Eio.Cancel.Cancelled _ as e -> raise e
                     | exn ->
                       Log.Keeper.warn "trust_observatory reputation failed for %s: %s"
                         m.name (Printexc.to_string exn);
                       `Null)
                  in
                  let thompson =
                    let stats = Thompson_sampling.get_stats m.name in
                    `Assoc [
                      ("alpha", `Float stats.Thompson_sampling.alpha);
                      ("beta", `Float stats.Thompson_sampling.beta);
                      ("score", `Float (stats.alpha /. (stats.alpha +. stats.beta)));
                      ("selections", `Int stats.selections);
                      ("votes_up", `Int stats.total_votes_up);
                      ("votes_down", `Int stats.total_votes_down);
                    ]
                  in
                  let accountability =
                    accountability_summary ~keeper_name:m.name
                      ~agent_name:m.agent_name
                  in
                  `Assoc [
                    ("reputation", reputation);
                    ("accountability", accountability);
                    ("thompson", thompson);
                  ]
              in
              let runtime_trust =
                if compact
                then Keeper_runtime_trust_snapshot.summary_json ~config ~meta:m
                else Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta:m
              in
              let attention_fields =
                attention_fields_with_runtime_trust attention_fields runtime_trust
              in
              let detail_fields =
                if compact then []
                else [
                  ("last_metrics", match last_metrics with None -> `Null | Some j -> j);
                  ("metrics_series", metrics_series);
                  ("metrics_24h", metrics_24h);
                  ("memory_bank", memory_bank_json);
                  ("conversation_tail", conversation_tail);
                  ("k2k_recent", k2k_recent);
                  ("trust_observatory", trust_observatory);
                ]
              in
	              let profile = Dashboard_execution_helpers.get_agent_profile m.name in
	              let lifecycle_phase =
	                Option.map
	                  (fun (entry : Keeper_registry.registry_entry) ->
	                    Keeper_state_machine.phase_to_string entry.phase)
	                  registry_entry
	              in
	              let pipeline_stage =
	                match registry_entry with
	                | Some entry ->
	                  Keeper_status_runtime.pipeline_stage_of_phase entry.phase
	                | None -> "offline"
	              in
	              let pipeline_stage_detail =
	                match registry_entry with
	                | Some entry ->
	                  Keeper_status_runtime.pipeline_stage_detail_of_phase entry.phase
	                | None -> "registry_absent"
	              in
		            `Assoc ([
	              ("name", `String m.name);
	              ("pipeline_stage", `String pipeline_stage);
	              ("lifecycle_phase", Json_util.string_opt_to_json lifecycle_phase);
	              ("pipeline_stage_detail", `String pipeline_stage_detail);
	              ("runtime_class", `String "keeper");
              ("phase", Json_util.string_opt_to_json phase);
              ("conditions", conditions_json);
              ("outcomes", outcomes_json);
            ] @ runtime_blocker_fields @ attention_fields @ [
              ("supervisor_diagnostics", supervisor_diagnostics);
              ("agent_name", `String m.agent_name);
              ( "keeper_id",
                match m.keeper_id with
                | Some keeper_id ->
                    `String (Keeper_id.Uid.to_string keeper_id)
                | None -> `Null );
              ("emoji", `String profile.emoji);
              ("koreanName", `String profile.korean_name);
              ("trace_id", `String (Keeper_id.Trace_id.to_string m.runtime.trace_id));
              ("generation", `Int m.runtime.generation);
              ( "current_task_id",
                Json_util.string_opt_to_json
                  (Option.map Keeper_id.Task_id.to_string m.current_task_id) );
              ("active_goal_ids", `List (List.map (fun goal_id -> `String goal_id) m.active_goal_ids));
              ("created_at", `String m.created_at);
              ("updated_at", `String m.updated_at);
              ("trace_history_count", `Int trace_history_count);
              ("active_goal_ids",
                `List (List.map (fun goal_id -> `String goal_id) m.active_goal_ids));
              ("goal", if include_goals then `String m.goal else `Null);
              ("short_goal", if include_goals then `String m.short_goal else `Null);
              ("mid_goal", if include_goals then `String m.mid_goal else `Null);
              ("long_goal", if include_goals then `String m.long_goal else `Null);
              ( "goal_horizons",
                if include_goals then
                  `Assoc [
                    ("short", `String m.short_goal);
                    ("mid", `String m.mid_goal);
                    ("long", `String m.long_goal);
                  ]
                else
                  `Null );
              ( "active_goals_tree",
                if (not compact) && include_goals && m.active_goal_ids <> [] then
                  let all_goals = Goal_store.list_goals config () in
                  let linked = List.filter (fun (g : Goal_store.goal) ->
                    List.mem g.id m.active_goal_ids) all_goals in
                  let tasks = Workspace.get_tasks_safe config in
                  let forest =
                    Dashboard_goals.build_forest ~config ~goals:linked ~tasks
                  in
                  `Assoc [
                    ("count", `Int (List.length linked));
                    ("nodes", `List (List.map Dashboard_goals.tree_node_to_json forest));
                  ]
                else
                  `Null );
                ("will", if String.trim m.will = "" then `Null else `String m.will);              ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
              ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
              ("self_model", `Assoc [
                ("will", if String.trim m.will = "" then `Null else `String m.will);
                ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
                ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
              ]);
              ("models", `List []);
              ("models_resolved", `List []);
              ("primary_model", `Null);
              ("active_model", `Null);
              ("next_model_hint", `Null);
              ("sandbox_profile",
                `String (Keeper_types_profile_sandbox.sandbox_profile_to_string m.sandbox_profile));
              ("sandbox_target", `String sandbox_target);
              ("sandbox_last_error",
                Json_util.string_opt_to_json sandbox_last_error);
              ("runtime_contract", runtime_contract);
              ("goal_progress", goal_progress);
              ("blocked_task_count", `Int blocked_task_count);
              ("approval_policy_effective", approval_policy_effective);
              ("runtime_trust", runtime_trust);
              ("paused", `Bool m.paused);
              ("keepalive_running", `Bool keepalive_running);
              ("autoboot_enabled", `Bool m.autoboot_enabled);
              ("auto_handoff", `Bool m.auto_handoff);
              ("handoff_threshold", `Float m.handoff_threshold);
              ("agent", agent);
              ( "status",
                `String
                  (Keeper_status_runtime.keeper_surface_status ~agent_status:agent
                     ~diagnostic) );
              ("keeper_age_s", `Float keeper_age_s);
              ("uptime_hours", `Float (keeper_age_s /. Masc_time_constants.hour));
              ("last_turn_ago_s", `Float last_turn_ago_s);
              ("last_handoff_ago_s", `Float last_handoff_ago_s);
              ("last_compaction_ago_s", `Float last_compaction_ago_s);
              ("last_proactive_ago_s", `Float last_proactive_ago_s);
              ("last_visible_proactive_ago_s", `Float last_visible_proactive_ago_s);
              ("last_activity_ago_s", `Float last_activity_ago_s);
              ("handoff_count_total", `Int trace_history_count);
              ("total_turns", `Int m.runtime.usage.total_turns);
              ("total_input_tokens", `Int m.runtime.usage.total_input_tokens);
              ("total_output_tokens", `Int m.runtime.usage.total_output_tokens);
              ("total_tokens", `Int m.runtime.usage.total_tokens);
              ("total_cost_usd", `Float m.runtime.usage.total_cost_usd);
              ("last_model_used", `Null);
              ("last_usage", `Assoc [
                ("input_tokens", `Int m.runtime.usage.last_input_tokens);
                ("output_tokens", `Int m.runtime.usage.last_output_tokens);
                ("total_tokens", `Int m.runtime.usage.last_total_tokens);
              ]);
              ("last_latency_ms", last_latency_ms_json m.runtime.usage.last_latency_ms);
              ("compaction_count", `Int m.runtime.compaction_rt.count);
              ("last_compaction_saved_tokens", `Int last_compaction_saved_tokens);
              ("compaction_profile", `String m.compaction.profile);
              ("compaction_ratio_gate", `Float compact_ratio_gate);
              ("compaction_message_gate", `Int compact_message_gate);
              ("compaction_token_gate", `Int compact_token_gate);
              ("autoboot_enabled", `Bool m.autoboot_enabled);
              ("proactive_enabled", `Bool m.proactive.enabled);
              ("proactive_idle_sec", `Int m.proactive.idle_sec);
              ("proactive_cooldown_sec", `Int m.proactive.cooldown_sec);
              ("proactive_count_total", `Int m.runtime.proactive_rt.count_total);
              ("proactive_visible_count_total", `Int m.runtime.proactive_rt.visible_count_total);
              ("autonomous_turn_count", `Int m.runtime.autonomous_turn_count);
              ("autonomous_text_turn_count", `Int m.runtime.autonomous_text_turn_count);
              ("autonomous_tool_turn_count", `Int m.runtime.autonomous_tool_turn_count);
              ("board_reactive_turn_count", `Int m.runtime.board_reactive_turn_count);
              ("mention_reactive_turn_count", `Int m.runtime.mention_reactive_turn_count);
              ("noop_turn_count", `Int m.runtime.noop_turn_count);
              ("autonomous_action_count", `Int m.runtime.autonomous_action_count);
              ("last_autonomous_action_at",
                if String.trim m.runtime.last_autonomous_action_at = ""
                then `Null
                else `String m.runtime.last_autonomous_action_at);
              ("last_proactive_ts", `Float m.runtime.proactive_rt.last_ts);
              ("last_visible_proactive_ts", `Float m.runtime.proactive_rt.last_visible_ts);
              ( "last_proactive_outcome"
              , `String
                  (Keeper_meta_contract.proactive_cycle_outcome_to_string
                     m.runtime.proactive_rt.last_outcome) );
              ("last_proactive_reason",
                if String.trim m.runtime.proactive_rt.last_reason = ""
                then `Null
                else `String m.runtime.proactive_rt.last_reason);
	              ("last_proactive_preview",
	                if String.trim m.runtime.proactive_rt.last_preview = ""
	                then `Null
	                else `String m.runtime.proactive_rt.last_preview);
            ]
            @ Keeper_status_bridge.social_runtime_fields_json m
            @ [
	              ("skill_primary", Json_util.string_opt_to_json last_skill_primary);
	              ("skill_secondary",
	                `List (List.map (fun s -> `String s) last_skill_secondary));
	              ("skill_reason", Json_util.string_opt_to_json last_skill_reason);
              ("metrics_window", metrics_window_summary);
              ("metrics_24h_summary", metrics_24h_summary);
              ("memory_note_count",
                (match memory_bank_json with
                 | `Assoc fields ->
                     (match List.assoc_opt "total_notes" fields with
                      | Some n -> n
                      | None -> (match List.assoc_opt "total_files" fields with
                                 | Some n -> n
                                 | None -> `Int 0))
                 | _ -> `Int 0));
              ("memory_top_kind",
                (match memory_bank_json with
                 | `Assoc fields ->
                     (match List.assoc_opt "top_kind" fields with
                      | Some (`String _ as s) -> s
                      | _ -> `Null)
                 | _ -> `Null));
              ("memory_recent_note", Json_util.string_opt_to_json memory_recent_note);
              ("recent_input_preview", Json_util.string_opt_to_json (recent_preview_for_role "user"));
              ("recent_output_preview", Json_util.string_opt_to_json (recent_preview_for_role "assistant"));
              ("recent_tool_names", `List (List.map (fun item -> `String item) recent_tool_names));
              ("conversation_tail_count", `Int conversation_tail_count);
              ("conversation_raw_count", `Int conversation_raw_count);
              ("conversation_fragment_count", `Int conversation_fragment_count);
              ("conversation_fragment_filtered_count", `Int conversation_fragment_filtered_count);
              ("conversation_fragment_filter_enabled", `Bool history_fragment_filter_enabled);
              ("k2k_count", `Int k2k_count);
              ("k2k_mentions", k2k_mentions);
              ("last_handoff_event", match last_handoff_event with Some j -> j | None -> `Null);
              ("last_compaction_event", match last_compaction_event with Some j -> j | None -> `Null);
              ("provider_health", provider_health_json);
              ("trust", trust_json);
              ("context", context);
              ("context_source", context_source);
              ("runtime_warning_ctx_ratio", `Float runtime_warning_ctx_ratio);
              (* Eval feed: latest verdict snapshot for this keeper (RFC-MASC-005) *)
              ("eval_latest",
                let base_path = config.base_path in
                let try_name agent_name =
                  Dashboard_eval_feed.read_latest ~base_path ~agent_name ~limit:1
                in
                let snapshots =
                  match try_name m.name with
                  | (_ :: _) as ss -> ss
                  | [] when m.agent_name <> m.name -> try_name m.agent_name
                  | other -> other
                in
                match snapshots with
                | s :: _ ->
                    `Assoc [
                      ("coverage", `Float s.verdict.coverage);
                      ("all_passed", `Bool s.verdict.all_passed);
                      ("layer_count", `Int (List.length s.verdict.layer_results));
                      ("passed_count",
                        `Int (List_util.count_if
                          (fun (lr : Dashboard_eval_feed.layer_result_json) -> lr.passed)
                          s.verdict.layer_results));
                      ("failed_count",
                        `Int (List_util.count_if
                          (fun (lr : Dashboard_eval_feed.layer_result_json) -> not lr.passed)
                          s.verdict.layer_results));
                      ("timestamp", `Float s.timestamp);
                      ("baseline_status", Json_util.string_opt_to_json s.baseline_status);
                    ]
                | [] -> `Null);
            ] @ detail_fields)
          in
          Some summary)
    ) names);
  let summaries = Array.to_list results |> List.filter_map Fun.id in
  (* H-9 fix: include recent alerts so BAD alerts are visible on dashboard *)
  let recent_alerts =
    let alerts_path = Keeper_types_support.keeper_alerts_path config in
    let lines =
      Dashboard_http_helpers.keeper_tail_lines_or_empty ~site:"dashboard_keeper_alerts" alerts_path
        ~max_bytes:50000 ~max_lines:10
    in
    List.filter_map (fun line ->
      try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None
    ) lines
  in
  `Assoc [
    ("keepers", `List summaries);
    ("total", `Int (List.length summaries));
    ("recent_alerts", `List recent_alerts);
    ("alert_count", `Int (List.length recent_alerts));
  ]

let execution_trust_dashboard_json (config : Workspace.config) : Yojson.Safe.t =
  let keepers =
    match keepers_dashboard_json ~compact:true config with
    | `Assoc fields -> (
        match List.assoc_opt "keepers" fields with
        | Some (`List rows) ->
          rows
          |> List.map (fun row ->
                 `Assoc
                   [
                     ("name", Option.value ~default:`Null (Json_util.assoc_member_opt "name" row));
                     ("agent_name", Option.value ~default:`Null (Json_util.assoc_member_opt "agent_name" row));
                     ("keeper_id", Option.value ~default:`Null (Json_util.assoc_member_opt "keeper_id" row));
                     ("phase", Option.value ~default:`Null (Json_util.assoc_member_opt "phase" row));
                     ( "pipeline_stage",
                       Option.value ~default:`Null (Json_util.assoc_member_opt "pipeline_stage" row) );
                     ("status", Option.value ~default:`Null (Json_util.assoc_member_opt "status" row));
                     ("trace_id", Option.value ~default:`Null (Json_util.assoc_member_opt "trace_id" row));
                     ("generation", Option.value ~default:`Null (Json_util.assoc_member_opt "generation" row));
                     ("current_task_id", Option.value ~default:`Null (Json_util.assoc_member_opt "current_task_id" row));
                     ("active_goal_ids", Option.value ~default:`Null (Json_util.assoc_member_opt "active_goal_ids" row));
                     ("trust", Option.value ~default:`Null (Json_util.assoc_member_opt "trust" row));
                   ])
        | _ -> [])
    | _ -> []
  in
  let now = Unix.gettimeofday () in
  let keeper_names = keeper_names config in
  let keepers_root = Workspace.keepers_runtime_dir config in
  let exists = Sys.file_exists keepers_root in
  let entry_count = count_execution_receipt_entries config keeper_names in
  let latest_ts = latest_receipt_ts_of_keeper_rows keepers in
  let coverage_gaps = execution_receipt_coverage_gaps config in
  let coverage_gap = List.rev coverage_gaps |> List.find_opt (fun _ -> true) in
  `Assoc
    ([
      ("source", `String execution_trust_source);
      ("producer", `String execution_trust_producer);
      ("durable_store", `String (execution_receipt_store_pattern config));
      ("dashboard_surface", `String execution_trust_dashboard_surface);
      ("freshness_slo_s", `Float execution_trust_freshness_slo_s);
      ("entry_count", `Int entry_count);
      ("exists", `Bool exists);
      ("generated_at", `String (Masc_domain.now_iso ()));
      ("keepers", `List keepers);
      ("total", `Int (List.length keepers));
      ("coverage_gaps", `List coverage_gaps);
      ("coverage_gap_count", `Int (List.length coverage_gaps));
    ]
    @ freshness_fields ~now latest_ts
    @ source_health_fields
        ~now ~exists ~entry_count ~latest_ts ?coverage_gap ())

(* Per-keeper snapshot/config rendering extracted to
   [Dashboard_http_keeper_snapshot] (godfile decomp). *)
include Dashboard_http_keeper_snapshot
