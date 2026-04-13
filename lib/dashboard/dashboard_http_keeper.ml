(** Dashboard HTTP keeper — keepers_dashboard_json rendering.

    Extracted from server_dashboard_http.ml. Contains the keeper dashboard
    rendering: per-keeper metrics series, 24h buckets, conversation history,
    memory bank, and diagnostic summaries. *)


open Dashboard_http_helpers
open Keeper_status_bridge

include Dashboard_http_keeper_detail

(** Context-ratio thresholds for keeper health scoring.
    These are distinct from Dashboard.ctx_* (compaction triggers) —
    health scoring penalizes keepers approaching context limits.
    Values sourced from [Env_config_keeper.DashboardHealth]. *)
let health_ctx_critical = Env_config_keeper.DashboardHealth.ctx_critical
let health_ctx_warn = Env_config_keeper.DashboardHealth.ctx_warn
let health_penalty_critical = Env_config_keeper.DashboardHealth.penalty_critical
let health_penalty_warn = Env_config_keeper.DashboardHealth.penalty_warn

(** Compute keeper health score (0-100). Pure function.
    Inputs: restart_count, max_restarts, recent_crash_count,
            is_dead, context_ratio (0.0-1.0). *)
let compute_health_score
    ~restart_count ~max_restarts ~recent_crash_count
    ~is_dead ~context_ratio =
  if is_dead then 0
  else
    let budget_penalty =
      if max_restarts <= 0 then 0.0
      else
        let ratio = float_of_int restart_count /. float_of_int max_restarts in
        Float.min 1.0 ratio *. 40.0
    in
    let crash_penalty =
      Float.min 30.0 (float_of_int recent_crash_count *. 10.0)
    in
    let context_penalty =
      if context_ratio > health_ctx_critical then health_penalty_critical
      else if context_ratio > health_ctx_warn then health_penalty_warn
      else 0.0
    in
    let raw = 100.0 -. budget_penalty -. crash_penalty -. context_penalty in
    Int.max 0 (Int.min 100 (Float.to_int raw))

(** Estimate seconds until Dead based on current restart_count and
    exponential backoff schedule. Returns None if already dead or
    restart_count >= max_restarts. *)
let estimate_dead_eta_sec ~restart_count ~max_restarts =
  if max_restarts <= 0 || restart_count >= max_restarts then None
  else
    let total = ref 0.0 in
    for i = restart_count to max_restarts - 1 do
      total := !total +. Keeper_supervisor.backoff_delay i
    done;
    Some !total

let prompt_block_json key =
  let resolved = Prompt_registry.resolve_prompt key in
  `Assoc
    [
      ("key", `String key);
      ("source", `String resolved.source);
      ("text", `String resolved.effective);
    ]

let tokens_per_sec_json ~tokens ~latency_ms =
  if tokens <= 0 || latency_ms <= 0 then `Null
  else `Float ((float_of_int tokens *. 1000.0) /. float_of_int latency_ms)

let keeper_names (config : Room.config) =
  Keeper_types.keeper_names config

let keeper_count (config : Room.config) : int =
  List.length (keeper_names config)

let keepers_dashboard_json ?(compact = false) (config : Room.config) : Yojson.Safe.t =
  let include_goals = bool_of_env "MASC_DASHBOARD_INCLUDE_GOALS" in
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
    Filename.concat (Room.masc_root_dir config) "keepers"
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
  (* Parallel keeper I/O: each keeper's metadata + metrics reads run concurrently.
     Results are collected into a shared ref array, then filter_map'd. *)
  let results = Array.make (List.length names) None in
  Eio.Fiber.all
    (List.mapi (fun idx name -> fun () ->
      results.(idx) <- (
      match Keeper_types.read_meta config name with
      | Error _ | Ok None -> None
      | Ok (Some (m : Keeper_types.keeper_meta)) ->
          let agent = Keeper_exec_status.parse_agent_status config ~agent_name:m.agent_name in

          let created_ts =
            Resilience.Time.parse_iso8601_opt m.created_at
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
          let active_model = Keeper_exec_status.active_model_of_meta m in
          let next_model_hint = Keeper_exec_status.next_model_hint_of_meta m in
          let cascade_models =
            Oas_model_resolve.models_of_cascade_name m.cascade_name
          in
          let primary_model =
            match cascade_models with
            | model :: _ -> model
            | [] -> ""
          in
          let primary_model_norm = normalize_model_name primary_model in
          let last_compaction_saved_tokens =
            max 0 (m.runtime.compaction_rt.last_before_tokens - m.runtime.compaction_rt.last_after_tokens)
          in

          let metrics_store = Keeper_types.keeper_metrics_store config m.name in
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
              let metrics_path = Keeper_types.keeper_metrics_path config m.name in
              Keeper_memory.read_file_tail_lines metrics_path
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
	            match List.rev parsed_metrics with
	            | latest :: _ -> Some latest
	            | [] -> None
	          in
	          let (last_skill_primary, last_skill_secondary, last_skill_reason) =
	            let open Yojson.Safe.Util in
	            let rec find_latest = function
	              | [] -> (None, [], None)
	              | j :: tl ->
	                  (match Safe_ops.json_string_opt "skill_primary" j with
	                   | Some primary when String.trim primary <> "" ->
	                       let secondary =
	                         match j |> member "skill_secondary" with
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

          let models_resolved =
            `List (List.filter_map (fun label ->
              match String.index_opt label ':' with
              | Some i ->
                  let provider = String.sub label 0 i in
                  let model_id = String.sub label (i + 1) (String.length label - i - 1) in
                  Some (`Assoc [
                    ("provider", `String provider);
                    ("model_id", `String model_id);
                    ("max_context", `Int 0);
                  ])
              | None -> None
            ) cascade_models)
          in

          (* In compact mode (used by execution surface), skip heavy memory bank I/O.
             Full memory bank is only needed for individual keeper detail view. *)
          let (memory_bank_json, memory_recent_note) =
            if compact then
              (`Assoc [("total_files", `Int 0); ("skipped", `Bool true)], None)
            else
              let summary =
                Keeper_memory.read_keeper_memory_summary
                  config
                  ~name:m.name
                  ~max_bytes:120000
                  ~max_lines:200
                  ~recent_limit:4
              in
              let note = match summary.Keeper_memory.recent_notes with
                | row :: _ -> Some row.Keeper_memory.text
                | [] -> None
              in
              (Keeper_memory.memory_summary_to_json summary, note)
          in
          let history_path =
            Filename.concat
              (Filename.concat (Keeper_types.session_base_dir config) (Keeper_id.Trace_id.to_string m.runtime.trace_id))
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
          let reconcile_status =
            if Keeper_manual_reconcile.is_pending config m.name then
                Some "manual_reconcile_required"
            else
              match registry_entry with
              | Some entry when
                  entry.turn_consecutive_failures > 0
                  && (match entry.last_failure_reason with
                      | Some reason ->
                          Keeper_registry.failure_reason_requires_manual_reconcile reason
                      | None -> false) ->
                  Some "manual_reconcile_required"
              | _ -> None
          in
          let runtime_blocker_fields =
            runtime_blocker_fields_json config m
          in
          let supervisor_diagnostics =
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
                `Assoc [
                  ("restart_count", `Int entry.restart_count);
                  ("max_restarts", `Int max_restarts);
                  ("crash_log", `List combined_log);
                  ("last_failure_reason",
                    match entry.last_failure_reason with
                    | Some r -> `String (Keeper_registry.failure_reason_to_string r)
                    | None -> `Null);
                  ("dead_since",
                    match entry.dead_since_ts with
                    | Some ts -> `Float ts
                    | None -> `Null);
                  ("sp_events", `List shared_sp_events);
                  ("health_score", `Int health_score);
                  ("dead_eta_sec",
                    match estimate_dead_eta_sec
                      ~restart_count:entry.restart_count ~max_restarts with
                    | Some eta -> `Float eta
                    | None -> `Null);
                ]
            | None ->
                `Assoc [
                  ("restart_count", `Int 0);
                  ("max_restarts", `Int max_restarts);
                  ("crash_log", `List []);
                  ("last_failure_reason", `Null);
                  ("dead_since", `Null);
                  ("sp_events", `List []);
                  ("health_score", `Int 100);
                  ("dead_eta_sec", `Null);
                ]
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
                (let effective_models =
                   Oas_model_resolve.models_of_cascade_name m.cascade_name
                 in
                 let cfgs = Llm_provider.Cascade_config.parse_model_strings effective_models in
                 match cfgs with
                 | [] when effective_models <> [] ->
                     `Assoc [("has_checkpoint", `Bool false)]
                 | _ ->
                     let primary_max_context =
                       Oas_model_resolve.resolve_primary_max_context effective_models
                     in
                     let base_dir = Keeper_types.session_base_dir config in
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
                           ("context_ratio", `Float (Keeper_exec_context.context_ratio c));
                           ("context_tokens", `Int (Keeper_exec_context.token_count c));
                           ("context_max", `Int c.max_tokens);
                           ("message_count", `Int (Keeper_exec_context.message_count c));
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
	                Keeper_exec_status.keeper_diagnostic_json
	                  ~meta:m
	                  ~agent_status:agent
	                  ~keepalive_running
	                  ~history_items:conversation_items
	                  ~now_ts
	                |> Keeper_exec_status.augment_keeper_diagnostic_json
	                     ~meta:m
	                     ~keepalive_running
	                     ~keepalive_started_at:(runtime_keepalive_started_at config m)
                     ~now_ts
              in
              (* C0: Trust Observatory — raw signals side-by-side, no synthesis.
                 Reputation (overall_score), Thompson (alpha/beta), Stress (5 kinds).
                 Gated by MASC_DECISION_LAYER_LEVEL >= 3. *)
              let trust_observatory =
                if compact
                   || Keeper_decision_audit.decision_layer_level () < 3
                then `Null
                else
                  let reputation =
                    (try
                       let rep = Agent_reputation.compute_reputation config ~agent_name:m.agent_name in
                       Agent_reputation.reputation_to_json rep
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
                  let stress =
                    let all_events = Agent_stress.recent 50 in
                    let keeper_events = List.filter (fun ev ->
                      match ev with
                      | `Assoc fields ->
                        (match List.assoc_opt "agent_name" fields with
                         | Some (`String n) -> n = m.name || n = m.agent_name
                         | _ -> false)
                      | _ -> false
                    ) all_events in
                    `List (List.filteri (fun i _ -> i < 10) keeper_events)
                  in
                  `Assoc [
                    ("reputation", reputation);
                    ("thompson", thompson);
                    ("stress_recent", stress);
                  ]
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
	            `Assoc ([
              ("name", `String m.name);
              ("pipeline_stage", `String
                (match registry_entry with
                 | Some entry ->
                   Keeper_exec_status.pipeline_stage_of_phase entry.phase
                 | None -> "offline"));
              ("runtime_class", `String "keeper");
              ("phase",
                match phase with
                | Some p -> `String p
                | None -> `Null);
              ("reconcile_status",
                match reconcile_status with
                | Some status -> `String status
                | None -> `Null);
            ] @ runtime_blocker_fields @ [
              ("supervisor_diagnostics", supervisor_diagnostics);
              ("agent_name", `String m.agent_name);
              ("emoji", `String (let (e, _) = get_agent_identity m.name in e));
              ("koreanName", `String (let (_, k) = get_agent_identity m.name in k));
              ("trace_id", `String (Keeper_id.Trace_id.to_string m.runtime.trace_id));
              ("generation", `Int m.runtime.generation);
              ("created_at", `String m.created_at);
              ("updated_at", `String m.updated_at);
              ("trace_history_count", `Int trace_history_count);
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
                if include_goals && m.active_goal_ids <> [] then
                  let all_goals = Goal_store.list_goals config () in
                  let linked = List.filter (fun (g : Goal_store.goal) ->
                    List.mem g.id m.active_goal_ids) all_goals in
                  let tasks = Room.get_tasks_safe config in
                  let forest = Dashboard_goals.build_forest ~goals:linked ~tasks in
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
              ("models", `List (List.map (fun s -> `String s) cascade_models));
              ("models_resolved", models_resolved);
              ("primary_model", `String primary_model);
              ("active_model", `String active_model);
              ("next_model_hint", Json_util.string_opt_to_json next_model_hint);
              ("room_scope", `String m.room_scope);
              ("paused", `Bool m.paused);
              ("keepalive_running", `Bool keepalive_running);
              ("auto_handoff", `Bool m.auto_handoff);
              ("handoff_threshold", `Float m.handoff_threshold);
              ("agent", agent);
              ( "status",
                `String
                  (Keeper_exec_status.keeper_surface_status ~agent_status:agent
                     ~diagnostic) );
              ("keeper_age_s", `Float keeper_age_s);
              ("uptime_hours", `Float (keeper_age_s /. 3600.0));
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
              ("last_model_used", `String m.runtime.usage.last_model_used);
              ("last_usage", `Assoc [
                ("input_tokens", `Int m.runtime.usage.last_input_tokens);
                ("output_tokens", `Int m.runtime.usage.last_output_tokens);
                ("total_tokens", `Int m.runtime.usage.last_total_tokens);
              ]);
              ("last_latency_ms", `Int m.runtime.usage.last_latency_ms);
              ("compaction_count", `Int m.runtime.compaction_rt.count);
              ("last_compaction_saved_tokens", `Int last_compaction_saved_tokens);
              ("compaction_profile", `String m.compaction.profile);
              ("compaction_ratio_gate", `Float compact_ratio_gate);
              ("compaction_message_gate", `Int compact_message_gate);
              ("compaction_token_gate", `Int compact_token_gate);
              ("proactive_enabled", `Bool m.proactive.enabled);
              ("proactive_idle_sec", `Int m.proactive.idle_sec);
              ("proactive_cooldown_sec", `Int m.proactive.cooldown_sec);
              ("proactive_count_total", `Int m.runtime.proactive_rt.count_total);
              ("proactive_visible_count_total", `Int m.runtime.proactive_rt.visible_count_total);
              ("social_model", `String m.social_model);
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
                  (Keeper_types.proactive_cycle_outcome_to_string
                     m.runtime.proactive_rt.last_outcome) );
              ("last_proactive_reason",
                if String.trim m.runtime.proactive_rt.last_reason = ""
                then `Null
                else `String m.runtime.proactive_rt.last_reason);
              ("last_speech_act",
                if String.trim m.runtime.last_speech_act = ""
                then `Null
                else `String m.runtime.last_speech_act);
              ("last_blocker",
                if String.trim m.runtime.last_blocker = ""
                then `Null
                else `String m.runtime.last_blocker);
              ("last_need",
                if String.trim m.runtime.last_need = ""
                then `Null
                else `String m.runtime.last_need);
	              ("last_proactive_preview",
	                if String.trim m.runtime.proactive_rt.last_preview = ""
	                then `Null
	                else `String m.runtime.proactive_rt.last_preview);
	              ("skill_primary",
	                match last_skill_primary with
	                | Some s -> `String s
	                | None -> `Null);
	              ("skill_secondary",
	                `List (List.map (fun s -> `String s) last_skill_secondary));
	              ("skill_reason",
	                match last_skill_reason with
	                | Some s -> `String s
	                | None -> `Null);
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
              ("memory_recent_note",
                match memory_recent_note with
                | Some text -> `String text
                | None -> `Null);
              ("recent_input_preview",
                match recent_preview_for_role "user" with
                | Some text -> `String text
                | None -> `Null);
              ("recent_output_preview",
                match recent_preview_for_role "assistant" with
                | Some text -> `String text
                | None -> `Null);
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
              ("context", context);
              ("context_source", context_source);
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
                        `Int (List.length (List.filter
                          (fun (lr : Dashboard_eval_feed.layer_result_json) -> lr.passed)
                          s.verdict.layer_results)));
                      ("failed_count",
                        `Int (List.length (List.filter
                          (fun (lr : Dashboard_eval_feed.layer_result_json) -> not lr.passed)
                          s.verdict.layer_results)));
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
    let alerts_path = Keeper_types.keeper_alerts_path config in
    let lines =
      Keeper_memory.read_file_tail_lines alerts_path ~max_bytes:50000 ~max_lines:10
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

(** Build a structured config JSON for a single keeper, grouped by category.
    Returns (http_status, json). *)
let keeper_config_json (config : Room.config) (name : string)
    : [ `OK | `Not_found ] * Yojson.Safe.t =
  match Keeper_types.read_meta config name with
  | Error msg ->
      (`Not_found, `Assoc [ ("error", `String msg) ])
  | Ok None ->
      (`Not_found,
       `Assoc [ ("error", `String (Printf.sprintf "keeper %S not found" name)) ])
  | Ok (Some (m : Keeper_types.keeper_meta)) ->
      (* bootstrap_runtime is called at server startup — skip here to
         avoid blocking the HTTP handler with Eio.Mutex + file I/O (#3335). *)
      let active_model = Keeper_exec_status.active_model_of_meta m in
      let persona_extended =
        Keeper_types_profile.load_persona_extended m.name
        |> Option.value ~default:""
      in
      let effective_system_prompt =
        Keeper_prompt.build_keeper_system_prompt
          ~goal:m.goal ~short_goal:m.short_goal ~mid_goal:m.mid_goal
          ~long_goal:m.long_goal ~will:m.will
          ~needs:m.needs ~desires:m.desires ~instructions:m.instructions
          ~persona_extended ~keeper_name:m.name ()
      in
      let prompt =
        `Assoc [
          ("goal", `String m.goal);
          ("short_goal", `String m.short_goal);
          ("mid_goal", `String m.mid_goal);
          ("long_goal", `String m.long_goal);
          ("will", `String m.will);
          ("needs", `String m.needs);
          ("desires", `String m.desires);
          ("instructions", `String m.instructions);
          ( "system_prompt_blocks",
            `Assoc
              [
                ("constitution", prompt_block_json Keeper_prompt_names.constitution);
                ("world", prompt_block_json Keeper_prompt_names.world);
                ("capabilities", prompt_block_json Keeper_prompt_names.capabilities);
              ] );
          ("effective_system_prompt", `String effective_system_prompt);
        ]
      in
      let execution =
        `Assoc [
          ( "models",
            `List
              (List.map (fun s -> `String s)
                 (Oas_model_resolve.models_of_cascade_name m.cascade_name)) );
          ("active_model", `String active_model);
          ("verify", `Bool false);
        ]
      in
      let compaction =
        `Assoc [
          ("profile", `String m.compaction.profile);
          ("ratio_gate", `Float m.compaction.ratio_gate);
          ("message_gate", `Int m.compaction.message_gate);
          ("token_gate", `Int m.compaction.token_gate);
          ("cooldown_sec", `Int m.compaction.cooldown_sec);
        ]
      in
      let proactive =
        `Assoc [
          ("enabled", `Bool m.proactive.enabled);
          ("idle_sec", `Int m.proactive.idle_sec);
          ("cooldown_sec", `Int m.proactive.cooldown_sec);
        ]
      in
      let drift = drift_surface_json () in
      let handoff =
        `Assoc [
          ("auto", `Bool m.auto_handoff);
          ("threshold", `Float m.handoff_threshold);
          ("cooldown_sec", `Int m.handoff_cooldown_sec);
        ]
      in
      let metrics =
        `Assoc [
          ("generation", `Int m.runtime.generation);
          ("total_turns", `Int m.runtime.usage.total_turns);
          ("total_input_tokens", `Int m.runtime.usage.total_input_tokens);
          ("total_output_tokens", `Int m.runtime.usage.total_output_tokens);
          ("total_tokens", `Int m.runtime.usage.total_tokens);
          ("total_cost_usd", `Float m.runtime.usage.total_cost_usd);
          ("last_model_used", `String m.runtime.usage.last_model_used);
          ("last_input_tokens", `Int m.runtime.usage.last_input_tokens);
          ("last_output_tokens", `Int m.runtime.usage.last_output_tokens);
          ("last_total_tokens", `Int m.runtime.usage.last_total_tokens);
          ("last_latency_ms", `Int m.runtime.usage.last_latency_ms);
          ( "last_total_tokens_per_sec",
            tokens_per_sec_json ~tokens:m.runtime.usage.last_total_tokens
              ~latency_ms:m.runtime.usage.last_latency_ms );
          ( "last_output_tokens_per_sec",
            tokens_per_sec_json ~tokens:m.runtime.usage.last_output_tokens
              ~latency_ms:m.runtime.usage.last_latency_ms );
          ("compaction_count", `Int m.runtime.compaction_rt.count);
        ]
      in
      let current_phase =
        Keeper_registry.get_phase ~base_path:config.base_path m.name
      in
      let pipeline_stage =
        match current_phase with
        | Some phase -> Keeper_exec_status.pipeline_stage_of_phase phase
        | None -> "offline"
      in
      let state_diagram =
        Keeper_state_machine.phase_to_mermaid
          ~current:(Option.value ~default:Keeper_state_machine.Offline current_phase)
      in
      let decision_pipeline_diagram =
        let phase = Option.value ~default:Keeper_state_machine.Offline current_phase in
        let stats = Thompson_sampling.get_stats m.agent_name in
        let tool_count = List.length (Keeper_exec_tools.keeper_allowed_tool_names m) in
        let recovery_floor_count =
          List.length (Keeper_tool_policy.failing_minimum_tool_names ())
        in
        Keeper_decision_audit.decision_pipeline_to_mermaid
          ~phase
          ~thompson_alpha:stats.alpha
          ~thompson_beta:stats.beta
          ~tool_count
          ~recovery_floor_count
      in
      let tools_access =
        let allowed = Keeper_exec_tools.keeper_allowed_tool_names m in
        let masc_tools =
          allowed
          |> List.filter (fun n -> String.starts_with ~prefix:"masc_" n)
        in
        let tool_preset = Keeper_types.tool_access_preset m.tool_access in
        let tool_also_allow = Keeper_types.tool_access_also_allowlist m.tool_access in
        let custom_allowlist = Keeper_types.tool_access_custom_allowlist m.tool_access in
        `Assoc [
          ("tool_access", Keeper_types.tool_access_to_json m.tool_access);
          ("tool_policy_mode",
            `String
              (match custom_allowlist with
               | Some _ -> "custom"
               | None -> "preset"));
          ("tool_preset",
            match tool_preset with
            | Some preset -> `String (Keeper_types.tool_preset_to_string preset)
            | None -> `Null);
          ("tool_also_allow", `List (List.map (fun s -> `String s) tool_also_allow));
          ("tool_custom_allowlist",
            `List
              (List.map (fun s -> `String s)
                 (Option.value ~default:[] custom_allowlist)));
          ("resolved_allowlist", `List (List.map (fun s -> `String s) allowed));
          ("tool_denylist", `List (List.map (fun s -> `String s) m.tool_denylist));
          ("active_masc_tool_count", `Int (List.length masc_tools));
          ("active_keeper_tool_count",
            `Int (List.length allowed - List.length masc_tools));
          ("total_active", `Int (List.length allowed));
        ]
      in
      (`OK,
       `Assoc [
         ("name", `String m.name);
         ("execution_scope", `String m.execution_scope);
         ("allowed_paths",
           `List (List.map (fun s -> `String s) m.allowed_paths));
         ("effective_allowed_paths",
           `List (List.map (fun s -> `String s)
             (Keeper_alerting_path.effective_allowed_paths ~meta:m)));
         ("pipeline_stage", `String pipeline_stage);
         ("state_diagram", `String state_diagram);
         ("decision_pipeline_diagram", `String decision_pipeline_diagram);
         ("prompt", prompt);
         ("execution", execution);
         ("compaction", compaction);
         ("proactive", proactive);
         ("drift", drift);
         ("auto_execution_session", auto_execution_session_surface_json ());
         ("auto_team_session", auto_execution_session_surface_json ());
         ("handoff", handoff);
         ("tools", tools_access);
         ("hooks", Keeper_hooks_oas.hook_introspection_json ());
         ("runtime", runtime_surface_json config m);
         ("coordination", coordination_surface_json m);
         ("sources", source_provenance_json config m);
         ("metrics", metrics);
       ])
