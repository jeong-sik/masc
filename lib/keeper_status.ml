(** Keeper_status — keeper status/list/trajectory handlers. *)

open Tool_args
open Keeper_types
open Keeper_memory
open Keeper_alerting
open Keeper_exec_persona
open Keeper_exec_tools
open Keeper_keepalive
open Keeper_execution
open Keeper_exec_status

type tool_result = Keeper_types.tool_result

include Keeper_status_bridge

let handle_keeper_status ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some m) ->
      let tail_turns = max 0 (get_int args "tail_turns" 3) in
      let tail_messages = max 0 (get_int args "tail_messages" 5) in
      let tail_compactions = max 0 (get_int args "tail_compactions" 10) in
      let tail_bytes = max 1_000 (get_int args "tail_bytes" 60_000) in
      let fast = get_bool args "fast" (keeper_status_fast_default ()) in
      let include_context = get_bool args "include_context" (not fast) in
      let include_metrics_overview =
        get_bool args "include_metrics_overview" (not fast)
      in
      let include_memory_bank = get_bool args "include_memory_bank" (not fast) in
      let include_history_tail = get_bool args "include_history_tail" (not fast) in
      let include_compaction_history =
        get_bool args "include_compaction_history" (not fast)
      in
      let models = m.models in
      (match model_specs_of_strings models with
       | Error e -> (false, "❌ " ^ e)
       | Ok specs ->
         let primary = match specs with m0 :: _ -> m0 | [] -> Llm_client.default_local_model_spec () in
         let base_dir = session_base_dir ctx.config in
         let ctx_opt =
           if include_context then
             let (_session, ctx_opt) =
               load_context_from_checkpoint
                 ~trace_id:m.trace_id
                 ~primary_model_max_tokens:primary.max_context
                 ~base_dir
             in
             ctx_opt
           else
             None
         in
         let ctx_stats =
           if not include_context then
             `Assoc [
               ("skipped", `Bool true);
               ("reason", `String "fast_or_disabled");
               ("has_checkpoint", `Null);
             ]
           else
             match ctx_opt with
             | None -> `Assoc [("has_checkpoint", `Bool false)]
             | Some c ->
               `Assoc [
                 ("has_checkpoint", `Bool true);
                 ("context_ratio", `Float (Context_manager.context_ratio c));
                 ("context_tokens", `Int c.token_count);
                 ("context_max", `Int c.max_tokens);
                 ("message_count", `Int (List.length c.messages));
               ]
         in
         let keepalive_running = keeper_keepalive_running m.name in
         let agent_status = parse_agent_status ctx.config ~agent_name:m.agent_name in
         let now_ts = Time_compat.now () in
         let created_ts =
           Resilience.Time.parse_iso8601_opt m.created_at |> Option.value ~default:0.0
         in
         let keeper_age_s = if created_ts <= 0.0 then 0.0 else now_ts -. created_ts in
         let last_turn_ago_s = if m.last_turn_ts <= 0.0 then 0.0 else now_ts -. m.last_turn_ts in
         let last_handoff_ago_s = if m.last_handoff_ts <= 0.0 then 0.0 else now_ts -. m.last_handoff_ts in
         let last_compaction_ago_s = if m.last_compaction_ts <= 0.0 then 0.0 else now_ts -. m.last_compaction_ts in
         let last_proactive_ago_s =
           if m.last_proactive_ts <= 0.0 then 0.0 else now_ts -. m.last_proactive_ts
         in
         let trace_history_count = List.length m.trace_history in
         let active_model = active_model_of_meta m in
         let next_model_hint = next_model_hint_of_meta m in
         let last_compaction_saved_tokens =
           max 0 (m.last_compaction_before_tokens - m.last_compaction_after_tokens)
         in
         let (compact_ratio_gate, compact_message_gate, compact_token_gate) =
           compaction_policy_of_keeper m
         in

         let models_resolved = `List (List.map (fun (s : Llm_client.model_spec) ->
           `Assoc [
             ("provider", `String (Llm_client.string_of_provider s.provider));
             ("model_id", `String s.model_id);
             ("max_context", `Int s.max_context);
             ("api_key_env", match s.api_key_env with None -> `Null | Some k -> `String k);
           ]
         ) specs) in

         let metrics_path = keeper_metrics_path ctx.config m.name in
         let memory_bank_path = keeper_memory_bank_path ctx.config m.name in
         let session_dir = keeper_session_dir ctx.config m.trace_id in
         let history_path = keeper_history_path ctx.config m.trace_id in

         let metrics_tail =
           let lines =
             read_file_tail_lines metrics_path
               ~max_bytes:tail_bytes
               ~max_lines:tail_turns
           in
           `List
             (List.filter_map
                (fun line ->
                  try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None)
                lines)
         in
         let metrics_window_lines =
           if include_metrics_overview then
             read_file_tail_lines metrics_path
               ~max_bytes:tail_bytes
               ~max_lines:(max tail_turns 200)
           else
             []
         in
         let metrics_overview =
           if include_metrics_overview then
             summarize_metrics_lines
               metrics_window_lines
               ~default_generation:m.generation
           else
             empty_metrics_summary
         in
         let last_skill_route =
           if not include_metrics_overview then
             None
           else
             let open Yojson.Safe.Util in
             let rec find_latest = function
               | [] -> None
               | line :: tl ->
                 (try
                    let j = Yojson.Safe.from_string line in
                    match Safe_ops.json_string_opt "skill_primary" j with
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
                      Some
                        (`Assoc
                           [
                             ("primary", `String primary);
                             ( "secondary",
                               `List (List.map (fun s -> `String s) secondary) );
                             ( "reason",
                               match reason with
                               | Some s -> `String s
                               | None -> `Null );
                           ])
                    | _ -> find_latest tl
                  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> find_latest tl)
             in
             find_latest (List.rev metrics_window_lines)
         in
         let memory_bank_summary =
           if include_memory_bank then
             read_keeper_memory_summary
               ctx.config
               ~name:m.name
               ~max_bytes:tail_bytes
               ~max_lines:(max (tail_turns * 10) 400)
               ~recent_limit:8
           else
             {
               total_notes = 0;
               last_ts_unix = 0.0;
               top_kind = None;
               kind_counts = [];
               recent_notes = [];
             }
         in

         let history_filter_fragments =
           bool_default_true_of_env "MASC_KEEPER_HISTORY_FRAGMENT_FILTER"
         in
         let (history_tail, history_raw_count, history_fragment_count, history_fragment_filtered_count) =
           if not include_history_tail then
             (`List [], 0, 0, 0)
           else
             let lines =
               read_file_tail_lines history_path
                 ~max_bytes:tail_bytes
                 ~max_lines:tail_messages
             in
             let open Yojson.Safe.Util in
             let (items_rev, raw_count, fragment_count, filtered_count) =
               List.fold_left
                 (fun (acc, raw_count, fragment_count, filtered_count) line ->
                   try
                     let j = Yojson.Safe.from_string line in
                     let role =
                       j |> member "role" |> to_string_option
                       |> Option.value ~default:"unknown"
                     in
                     let content =
                       j |> member "content" |> to_string_option
                       |> Option.value ~default:""
                     in
                     let ts_unix =
                       let ts0 = Safe_ops.json_float ~default:0.0 "ts_unix" j in
                       if ts0 > 0.0 then ts0
                       else Safe_ops.json_float ~default:0.0 "timestamp" j
                     in
                     let age_s =
                       if ts_unix > 0.0 then Some (max 0.0 (now_ts -. ts_unix))
                       else None
                     in
                     let role_lc = String.lowercase_ascii role in
                     let entry_kind =
                       match role_lc with
                       | "assistant" -> "self_talk"
                       | "user" -> "input"
                       | "tool" -> "tool_result"
                       | "system" -> "system"
                       | _ -> "other"
                     in
                     let is_fragment =
                       role_lc = "assistant"
                       && looks_fragmentary_history_text content
                     in
                     let should_filter = history_filter_fragments && is_fragment in
                     let preview =
                       if String.length content > 200 then
                         utf8_safe_prefix_bytes content ~max_bytes:200 ^ "..."
                       else content
                     in
                     let item =
                       `Assoc [
                         ("role", `String role);
                         ("kind", `String entry_kind);
                         ("is_fragment", `Bool is_fragment);
                         ("ts_unix", `Float ts_unix);
                         ("age_s", match age_s with Some v -> `Float v | None -> `Null);
                         ("content", `String preview);
                       ]
                     in
                     let acc = if should_filter then acc else item :: acc in
                     let filtered_count =
                       filtered_count + if should_filter then 1 else 0
                     in
                     ( acc,
                       raw_count + 1,
                       fragment_count + (if is_fragment then 1 else 0),
                       filtered_count )
                   with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> (acc, raw_count, fragment_count, filtered_count))
                 ([], 0, 0, 0) lines
             in
             (`List (List.rev items_rev), raw_count, fragment_count, filtered_count)
         in
         let history_items =
           match history_tail with
           | `List xs -> xs
           | _ -> []
         in
         let diagnostic =
           keeper_diagnostic_json
             ~meta:m
             ~agent_status
             ~keepalive_running
             ~history_items
             ~now_ts
           |> augment_keeper_diagnostic_json
                ~desired:(is_resident_keeper ctx.config m.name)
                ~meta:m
                ~keepalive_running
                ~keepalive_started_at:(keeper_keepalive_started_at m.name)
                ~now_ts
         in

         let compaction_history_tail =
           if not include_compaction_history then
             (`List [], 0)
           else
             let lines =
               read_file_tail_lines metrics_path
                 ~max_bytes:tail_bytes
                 ~max_lines:(max 200 (tail_compactions * 20))
             in
             let events_rev =
               List.fold_left
                 (fun acc line ->
                   try
                     let j = Yojson.Safe.from_string line in
                     let compacted = Safe_ops.json_bool ~default:false "compacted" j in
                     let memory_compaction_performed =
                       Safe_ops.json_bool ~default:false "memory_compaction_performed" j
                     in
                     if (not compacted) && (not memory_compaction_performed) then acc
                     else
                       let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
                       let age_s =
                         if ts_unix > 0.0 then Some (max 0.0 (now_ts -. ts_unix)) else None
                       in
                       let before_tokens = Safe_ops.json_int ~default:0 "compaction_before_tokens" j in
                       let after_tokens = Safe_ops.json_int ~default:0 "compaction_after_tokens" j in
                       let saved_tokens = max 0 (before_tokens - after_tokens) in
                       let memory_before_notes =
                         Safe_ops.json_int ~default:0 "memory_compaction_before_notes" j
                       in
                       let memory_after_notes =
                         Safe_ops.json_int ~default:0 "memory_compaction_after_notes" j
                       in
                       let memory_dropped_notes =
                         Safe_ops.json_int ~default:0 "memory_compaction_dropped_notes" j
                       in
                       let memory_invalid_dropped =
                         Safe_ops.json_int ~default:0 "memory_compaction_invalid_dropped" j
                       in
                       let event_kind =
                         if compacted && memory_compaction_performed then "context+memory"
                         else if compacted then "context"
                         else "memory"
                       in
                       let item =
                         `Assoc [
                           ("kind", `String event_kind);
                           ("channel", `String (Safe_ops.json_string ~default:"turn" "channel" j));
                           ("ts_unix", `Float ts_unix);
                           ("age_s", match age_s with Some v -> `Float v | None -> `Null);
                           ("trace_id", `String (Safe_ops.json_string ~default:"" "trace_id" j));
                           ("generation", `Int (Safe_ops.json_int ~default:m.generation "generation" j));
                           ("context_ratio", `Float (Safe_ops.json_float ~default:0.0 "context_ratio" j));
                           ("context_before_tokens", `Int before_tokens);
                           ("context_after_tokens", `Int after_tokens);
                           ("context_saved_tokens", `Int saved_tokens);
                           ( "context_trigger",
                             match Safe_ops.json_string_opt "compaction_trigger" j with
                             | Some reason when String.trim reason <> "" -> `String reason
                             | _ -> `Null );
                           ("memory_compaction_performed", `Bool memory_compaction_performed);
                           ("memory_before_notes", `Int memory_before_notes);
                           ("memory_after_notes", `Int memory_after_notes);
                           ("memory_dropped_notes", `Int memory_dropped_notes);
                           ("memory_invalid_dropped", `Int memory_invalid_dropped);
                           ( "memory_reason",
                             match Safe_ops.json_string_opt "memory_compaction_reason" j with
                             | Some reason when String.trim reason <> "" -> `String reason
                             | _ -> `Null );
                         ]
                       in
                       item :: acc
                   with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> acc)
                 [] lines
             in
             let events = List.rev events_rev in
             let total = List.length events in
             let start = max 0 (total - tail_compactions) in
             let tail = List.filteri (fun i _ -> i >= start) events in
             (`List tail, total)
        in
        let all_internal_tools =
          keeper_llm_tools |> List.map (fun tool -> tool.Llm_client.tool_name)
        in
        let allowed_tools = keeper_allowed_tool_names m in
        let blocked_internal_tools =
          all_internal_tools
          |> List.filter (fun name -> not (List.mem name allowed_tools))
        in

         let json = `Assoc [
           ("meta", meta_to_json m);
           ("goal", `String m.goal);
           ("short_goal", `String m.short_goal);
           ("mid_goal", `String m.mid_goal);
           ("long_goal", `String m.long_goal);
           ("goal_horizons", `Assoc [
             ("short", `String m.short_goal);
             ("mid", `String m.mid_goal);
             ("long", `String m.long_goal);
           ]);
           ("soul_profile", `String m.soul_profile);
           ("will", if String.trim m.will = "" then `Null else `String m.will);
           ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
           ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
           ("self_model", `Assoc [
             ("will", if String.trim m.will = "" then `Null else `String m.will);
             ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
             ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
           ]);
           ("keepalive_running", `Bool keepalive_running);
           ("agent", agent_status);
           ("diagnostic", diagnostic);
           ("keeper_age_s", `Float keeper_age_s);
           ("last_turn_ago_s", `Float last_turn_ago_s);
           ("last_handoff_ago_s", `Float last_handoff_ago_s);
           ("last_compaction_ago_s", `Float last_compaction_ago_s);
           ("last_proactive_ago_s", `Float last_proactive_ago_s);
           ("active_model", `String active_model);
           ("next_model_hint", match next_model_hint with Some s -> `String s | None -> `Null);
           ("trace_history_count", `Int trace_history_count);
           ("handoff_count_total", `Int trace_history_count);
           ("last_compaction_saved_tokens", `Int last_compaction_saved_tokens);
           ("lifecycle", `Assoc [
             ("created_at", `String m.created_at);
             ("updated_at", `String m.updated_at);
             ("uptime_hours", `Float (keeper_age_s /. 3600.0));
           ]);
           ("proactive", `Assoc [
             ("enabled", `Bool m.proactive_enabled);
             ("idle_sec", `Int m.proactive_idle_sec);
             ("cooldown_sec", `Int m.proactive_cooldown_sec);
             ("count_total", `Int m.proactive_count_total);
             ("last_ts", `Float m.last_proactive_ts);
             ("last_ago_s", `Float last_proactive_ago_s);
             ("last_reason",
               if String.trim m.last_proactive_reason = ""
               then `Null
               else `String m.last_proactive_reason);
             ("last_preview",
               if String.trim m.last_proactive_preview = ""
               then `Null
               else `String m.last_proactive_preview);
           ]);
           ("drift", `Assoc [
             ("enabled", `Bool m.drift_enabled);
             ("min_turn_gap", `Int m.drift_min_turn_gap);
             ("count_total", `Int m.drift_count_total);
             ("last_turn", `Int m.last_drift_turn);
             ("last_reason",
               if String.trim m.last_drift_reason = ""
               then `Null
               else `String m.last_drift_reason);
           ]);
           ("policy", `Assoc [
             ("mode", `String m.policy_mode);
             ("action_budget", `String m.policy_action_budget);
             ("reward_model_path",
               if String.trim m.policy_reward_model_path = ""
               then `Null
               else `String m.policy_reward_model_path);
             ("voice_enabled", `Bool m.policy_voice_enabled);
             ("shell_mode", `String m.policy_shell_mode);
             ("allowed_tools", string_list_to_json allowed_tools);
             ("available_internal_tools", string_list_to_json all_internal_tools);
             ("blocked_internal_tools", string_list_to_json blocked_internal_tools);
           ]);
           ("initiative", `Assoc [
             ("enabled", `Bool m.initiative_enabled);
             ("scope", `String m.initiative_scope);
             ("idle_sec", `Int m.initiative_idle_sec);
             ("cooldown_sec", `Int m.initiative_cooldown_sec);
             ("context_mode", `String m.initiative_context_mode);
             ("post_ttl_hours", `Int m.initiative_post_ttl_hours);
           ]);
           ("auto_team_session_enabled", `Bool m.auto_team_session_enabled);
           ("active_team_session_id",
             match m.active_team_session_id with
             | Some session_id -> `String session_id
             | None -> `Null);
           ("team_session_state", team_session_state_json ctx.config m);
           ("last_team_session_started_at",
             if String.trim m.last_team_session_started_at = "" then `Null
             else `String m.last_team_session_started_at);
           ("team_session_start_count_total",
             `Int m.team_session_start_count_total);
           ("team_session_bridge", team_session_bridge_json ctx.config m);
           ("compaction_policy", `Assoc [
             ("profile", `String m.compaction_profile);
             ("ratio_gate", `Float compact_ratio_gate);
             ("message_gate", `Int compact_message_gate);
             ("token_gate", `Int compact_token_gate);
             ("token_gate_enabled", `Bool (compact_token_gate > 0));
           ]);
           ("status_options", `Assoc [
             ("fast", `Bool fast);
             ("include_context", `Bool include_context);
             ("include_metrics_overview", `Bool include_metrics_overview);
             ("include_memory_bank", `Bool include_memory_bank);
             ("include_history_tail", `Bool include_history_tail);
             ("include_compaction_history", `Bool include_compaction_history);
           ]);
	           ("models_resolved", models_resolved);
	           ("context", ctx_stats);
	           ("skill_route", match last_skill_route with Some v -> v | None -> `Null);
	           ("metrics_overview", metrics_summary_to_json metrics_overview);
	           ("memory_bank", memory_summary_to_json memory_bank_summary);
           ("metrics_tail", metrics_tail);
           ("history_tail", history_tail);
           ("history_tail_count",
             match history_tail with
             | `List xs -> `Int (List.length xs)
             | _ -> `Int 0);
           ("history_raw_count", `Int history_raw_count);
           ("history_fragment_count", `Int history_fragment_count);
           ("history_fragment_filtered_count", `Int history_fragment_filtered_count);
           ("history_fragment_filter_enabled", `Bool history_filter_fragments);
           ("compaction_history_tail", fst compaction_history_tail);
           ("compaction_history_count", `Int (snd compaction_history_tail));
           ("storage_paths", `Assoc [
             ("meta", `String (keeper_meta_path ctx.config m.name));
             ("metrics", `String metrics_path);
             ("memory_bank", `String memory_bank_path);
             ("policy", `String (keeper_policy_log_path ctx.config m.name));
             ("feedback", `String (keeper_feedback_log_path ctx.config m.name));
             ("dataset_export", `String (keeper_dataset_export_path ctx.config m.name));
             ("session_dir", `String session_dir);
             ("history", `String history_path);
           ]);
         ] in
         (true, Yojson.Safe.pretty_to_string json))

let handle_keeper_list ctx args : tool_result =
  let limit = max 0 (get_int args "limit" 50) in
  let detailed = get_bool args "detailed" false in
  let dir = keeper_dir ctx.config in
  match Safe_ops.list_dir_safe dir with
  | Error e -> (false, "❌ " ^ e)
  | Ok files ->
    let keeper_names =
      files
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.map Filename.remove_extension
      |> List.filter validate_name
      |> List.sort String.compare
      |> take limit
    in
    if not detailed then
      let json = `Assoc [
        ("count", `Int (List.length keeper_names));
        ("keepers", `List (List.map (fun k -> `String k) keeper_names));
      ] in
      (true, Yojson.Safe.pretty_to_string json)
    else
      let now_ts = Time_compat.now () in
      let keepers =
        List.filter_map (fun name ->
          match read_meta ctx.config name with
          | Error _ -> None
          | Ok None -> None
          | Ok (Some m) ->
            let created_ts =
              Resilience.Time.parse_iso8601_opt m.created_at |> Option.value ~default:0.0
            in
            let keeper_age_s = if created_ts <= 0.0 then 0.0 else now_ts -. created_ts in
            let last_turn_ago_s = if m.last_turn_ts <= 0.0 then 0.0 else now_ts -. m.last_turn_ts in
            let last_proactive_ago_s =
              if m.last_proactive_ts <= 0.0 then 0.0 else now_ts -. m.last_proactive_ts
            in
            let active_model = active_model_of_meta m in
            let next_model_hint = next_model_hint_of_meta m in
            let trace_history_count = List.length m.trace_history in
            let last_compaction_saved_tokens =
              max 0 (m.last_compaction_before_tokens - m.last_compaction_after_tokens)
            in
            let (compact_ratio_gate, compact_message_gate, compact_token_gate) =
              compaction_policy_of_keeper m
            in
	            let metrics_path = keeper_metrics_path ctx.config m.name in
	            let metrics_window_lines =
	              read_file_tail_lines metrics_path ~max_bytes:120000 ~max_lines:120
	            in
	            let last_metrics =
	              match List.rev metrics_window_lines with
	              | line :: _ -> (try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None)
	              | [] -> None
	            in
	            let metrics_overview =
	              summarize_metrics_lines metrics_window_lines ~default_generation:m.generation
	            in
	            let last_skill_metrics =
	              let rec find_latest = function
	                | [] -> None
	                | line :: tl ->
	                    (try
	                       let j = Yojson.Safe.from_string line in
	                       match Safe_ops.json_string_opt "skill_primary" j with
	                       | Some primary when String.trim primary <> "" -> Some j
	                       | _ -> find_latest tl
	                     with Yojson.Json_error _ -> find_latest tl)
	              in
	              find_latest (List.rev metrics_window_lines)
	            in
            let memory_bank_summary =
              read_keeper_memory_summary
                ctx.config
                ~name:m.name
                ~max_bytes:120000
                ~max_lines:180
                ~recent_limit:3
            in
            let memory_recent_note =
              match memory_bank_summary.recent_notes with
              | row :: _ -> Some row.text
              | [] -> None
            in
            let continuity_reflection_hold_s =
              let cooldown = Float.of_int m.continuity_compaction_cooldown_sec in
              let last_reflection_ts =
                max m.last_continuity_update_ts m.last_proactive_ts
              in
              if cooldown <= 0.0 then
                0.0
              else if last_reflection_ts <= 0.0 then
                cooldown
              else
                let elapsed = now_ts -. last_reflection_ts in
                max 0.0 (cooldown -. elapsed)
            in
	            let context_json =
	              match last_metrics with
	              | None -> `Assoc [("source", `String "none")]
	              | Some metrics ->
	                `Assoc [
	                  ("source", `String "metrics");
	                  ("context_ratio", `Float (Safe_ops.json_float "context_ratio" metrics));
	                  ("context_tokens", `Int (Safe_ops.json_int "context_tokens" metrics));
	                  ("context_max", `Int (Safe_ops.json_int "context_max" metrics));
	                  ("message_count", `Int (Safe_ops.json_int "message_count" metrics));
	                ]
	            in
	            let skill_route_json =
	              let open Yojson.Safe.Util in
                  let configured_selection_mode = keeper_skill_selection_mode () in
                  let fallback_selection_mode_string, fallback_selection_provenance =
                    match configured_selection_mode with
                    | SkillSelectAgent -> ("agent", "judgment")
                    | SkillSelectHeuristic -> ("heuristic", "fallback")
                  in
	              match last_skill_metrics with
	              | None -> `Null
	              | Some metrics ->
	                  let primary = Safe_ops.json_string_opt "skill_primary" metrics in
	                  let secondary =
	                    match metrics |> member "skill_secondary" with
	                    | `List xs ->
	                        xs
	                        |> List.filter_map (fun v ->
	                             match v with `String s when String.trim s <> "" -> Some s | _ -> None)
	                    | _ -> []
	                  in
	                  let reason = Safe_ops.json_string_opt "skill_reason" metrics in
	                  `Assoc [
	                    ("primary", match primary with Some s -> `String s | None -> `Null);
	                    ("secondary", `List (List.map (fun s -> `String s) secondary));
	                    ("reason", match reason with Some s -> `String s | None -> `Null);
                        ( "selection_mode",
                          `String
                            (Safe_ops.json_string_opt "skill_selection_mode" metrics
                             |> Option.value ~default:fallback_selection_mode_string) );
                        ( "provenance",
                          `String
                            (Safe_ops.json_string_opt "skill_provenance" metrics
                             |> Option.value ~default:fallback_selection_provenance) );
                        ("authoritative", `Bool false);
	                  ]
	            in
	            Some (`Assoc [
              ("name", `String m.name);
              ("agent_name", `String m.agent_name);
              ("trace_id", `String m.trace_id);
              ("generation", `Int m.generation);
              ("goal", `String m.goal);
              ("short_goal", `String m.short_goal);
              ("mid_goal", `String m.mid_goal);
              ("long_goal", `String m.long_goal);
              ("goal_horizons", `Assoc [
                ("short", `String m.short_goal);
                ("mid", `String m.mid_goal);
                ("long", `String m.long_goal);
              ]);
              ("soul_profile", `String m.soul_profile);
              ("will", if String.trim m.will = "" then `Null else `String m.will);
              ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
              ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
              ("keepalive_running", `Bool (keeper_keepalive_running m.name));
              ("active_model", `String active_model);
              ("next_model_hint", match next_model_hint with Some s -> `String s | None -> `Null);
              ("keeper_age_s", `Float keeper_age_s);
              ("last_turn_ago_s", `Float last_turn_ago_s);
              ("last_proactive_ago_s", `Float last_proactive_ago_s);
              ("trace_history_count", `Int trace_history_count);
              ("handoff_count_total", `Int trace_history_count);
              ("compaction_count", `Int m.compaction_count);
              ("last_compaction_saved_tokens", `Int last_compaction_saved_tokens);
              ("compaction_profile", `String m.compaction_profile);
              ("compaction_ratio_gate", `Float compact_ratio_gate);
              ("compaction_message_gate", `Int compact_message_gate);
              ("compaction_token_gate", `Int compact_token_gate);
              ("proactive_enabled", `Bool m.proactive_enabled);
              ("proactive_idle_sec", `Int m.proactive_idle_sec);
              ("proactive_cooldown_sec", `Int m.proactive_cooldown_sec);
              ("proactive_count_total", `Int m.proactive_count_total);
              ("last_compaction_check_ts", `Float m.last_compaction_check_ts);
              ("last_compaction_decision",
                if String.trim m.last_compaction_decision = "" then `Null
                else `String m.last_compaction_decision);
              ("last_proactive_ts", `Float m.last_proactive_ts);
              ("last_proactive_reason",
                if String.trim m.last_proactive_reason = ""
                then `Null
                else `String m.last_proactive_reason);
              ("last_proactive_preview",
                if String.trim m.last_proactive_preview = ""
                then `Null
                else `String m.last_proactive_preview);
              ("continuity_summary",
                if String.trim m.continuity_summary = ""
                then `Null
                else `String m.continuity_summary);
              ("continuity_compaction_cooldown_sec", `Int m.continuity_compaction_cooldown_sec);
              ("continuity_reflection_hold_s", `Float continuity_reflection_hold_s);
              ("last_continuity_update_ts", `Float m.last_continuity_update_ts);
              ("drift_enabled", `Bool m.drift_enabled);
              ("drift_min_turn_gap", `Int m.drift_min_turn_gap);
              ("drift_count_total", `Int m.drift_count_total);
              ("policy_mode", `String m.policy_mode);
              ("policy_action_budget", `String m.policy_action_budget);
              ("policy_reward_model_path",
                if String.trim m.policy_reward_model_path = ""
                then `Null
                else `String m.policy_reward_model_path);
              ("auto_team_session_enabled", `Bool m.auto_team_session_enabled);
              ("active_team_session_id",
                match m.active_team_session_id with
                | Some session_id -> `String session_id
                | None -> `Null);
              ("team_session_state", team_session_state_json ctx.config m);
              ("last_team_session_started_at",
                if String.trim m.last_team_session_started_at = "" then `Null
                else `String m.last_team_session_started_at);
              ("team_session_start_count_total",
                `Int m.team_session_start_count_total);
              ("team_session_bridge", team_session_bridge_json ctx.config m);
              ("last_drift_turn", `Int m.last_drift_turn);
              ("last_drift_reason",
                if String.trim m.last_drift_reason = ""
                then `Null
                else `String m.last_drift_reason);
              ("memory_note_count", `Int memory_bank_summary.total_notes);
              ("memory_top_kind",
                match memory_bank_summary.top_kind with
                | Some kind -> `String kind
                | None -> `Null);
	              ("memory_recent_note",
	                match memory_recent_note with
	                | Some text -> `String text
	                | None -> `Null);
	              ("context", context_json);
	              ("skill_route", skill_route_json);
	              ("metrics_overview", metrics_summary_to_json metrics_overview);
	              ("memory_bank", memory_summary_to_json memory_bank_summary);
              ("storage_paths", `Assoc [
                ("meta", `String (keeper_meta_path ctx.config m.name));
                ("metrics", `String metrics_path);
                ("memory_bank", `String (keeper_memory_bank_path ctx.config m.name));
                ("policy", `String (keeper_policy_log_path ctx.config m.name));
                ("feedback", `String (keeper_feedback_log_path ctx.config m.name));
                ("dataset_export", `String (keeper_dataset_export_path ctx.config m.name));
                ("session_dir", `String (keeper_session_dir ctx.config m.trace_id));
                ("history", `String (keeper_history_path ctx.config m.trace_id));
              ]);
            ])
        ) keeper_names
      in
      let json = `Assoc [
        ("count", `Int (List.length keepers));
        ("keepers", `List keepers);
      ] in
      (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_trajectory ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "read error: " ^ e)
    | Ok None -> (false, Printf.sprintf "keeper not found: %s" name)
    | Ok (Some m) ->
      let limit = get_int args "limit" 20 in
      let masc_root = Filename.concat ctx.config.base_path ".masc" in
      let entries =
        Trajectory.read_entries ~masc_root ~keeper_name:m.name ~trace_id:m.trace_id
      in
      let total = List.length entries in
      (* Take the last N entries (most recent) *)
      let recent =
        if total <= limit then entries
        else
          let drop = total - limit in
          List.filteri (fun i _e -> i >= drop) entries
      in
      if recent = [] then
        (true, Printf.sprintf "Keeper %s (trace: %s) has no trajectory entries." name m.trace_id)
      else
        let json_list = List.map Trajectory.entry_to_json recent in
        let json = `Assoc [
          ("keeper", `String name);
          ("trace_id", `String m.trace_id);
          ("generation", `Int m.generation);
          ("total_entries", `Int total);
          ("showing", `Int (List.length recent));
          ("entries", `List json_list);
        ] in
        (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_eval ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "read error: " ^ e)
    | Ok None -> (false, Printf.sprintf "keeper not found: %s" name)
    | Ok (Some m) ->
      let scenario_file = get_string_opt args "scenario_file" in
      let masc_root = Filename.concat ctx.config.base_path ".masc" in
      let entries =
        Trajectory.read_entries ~masc_root ~keeper_name:m.name ~trace_id:m.trace_id
      in
      if entries = [] then
        (true, Printf.sprintf "Keeper %s has no trajectory data to evaluate." name)
      else
        let total = List.length entries in
        (* Build a lightweight eval summary from trajectory *)
        let tool_names =
          List.map (fun (e : Trajectory.tool_call_entry) -> e.tool_name) entries
        in
        let unique_tools =
          List.sort_uniq String.compare tool_names
        in
        let tool_counts =
          List.map
            (fun tn ->
              let c = List.length (List.filter (fun n -> n = tn) tool_names) in
              (tn, c))
            unique_tools
        in
        let tool_stats =
          List.map
            (fun (tn, c) -> `Assoc [("tool", `String tn); ("count", `Int c)])
            (List.sort (fun (_, a) (_, b) -> compare b a) tool_counts)
        in
        (* Check if scenario file is provided for deeper eval *)
        let scenario_info =
          match scenario_file with
          | None -> `String "none (trajectory-only eval)"
          | Some sf ->
            (match Eval_harness.load_scenarios_from_file sf with
             | Error e -> `String (Printf.sprintf "failed to load: %s" e)
             | Ok scenarios ->
               `String (Printf.sprintf "loaded %d scenarios from %s"
                 (List.length scenarios) sf))
        in
        let json = `Assoc [
          ("keeper", `String name);
          ("trace_id", `String m.trace_id);
          ("generation", `Int m.generation);
          ("total_turns", `Int m.total_turns);
          ("total_input_tokens", `Int m.total_input_tokens);
          ("total_output_tokens", `Int m.total_output_tokens);
          ("total_tool_calls", `Int total);
          ("unique_tools", `Int (List.length unique_tools));
          ("tool_distribution", `List tool_stats);
          ("scenario_file", scenario_info);
          ("autonomy_level", `String m.autonomy_level);
          ("autonomous_action_count", `Int m.autonomous_action_count);
        ] in
        (true, Yojson.Safe.pretty_to_string json)
