(** Keeper_status_detail — single-keeper detailed status handler.
    Split from keeper_status.ml.

    Server-side response cache: keyed on (name, updated_at, args_hash).
    Avoids expensive JSONL parsing and checkpoint loading when keeper
    state has not changed between consecutive status polls. *)

open Tool_args
open Keeper_types
open Keeper_memory
open Keeper_alerting
open Keeper_exec_tools
open Keeper_execution
open Keeper_exec_status
open Keeper_exec_status_metrics
open Keeper_status_bridge

type tool_result = Keeper_types.tool_result

(* ── Response cache ──────────────────────────────────── *)

type cache_entry = {
  updated_at : string;
  args_hash : string;
  response : string;
}

let _cache : (string, cache_entry) Hashtbl.t = Hashtbl.create 8

let invalidate_status_cache_for name =
  Hashtbl.remove _cache name

let invalidate_status_cache_all () =
  Hashtbl.clear _cache

let normalize_status_name = String.trim

let effective_status_name (ctx : _ context) args =
  match normalize_status_name (get_string args "name" "") with
  | "" -> normalize_status_name ctx.agent_name
  | value -> value

(** Hash the status-affecting args so different parameter combos
    get separate cache entries (e.g. fast=true vs fast=false). *)
let hash_status_args ctx args =
  let parts = [
    effective_status_name ctx args;
    string_of_bool (get_bool args "fast" false);
    string_of_bool (get_bool args "include_context" false);
    string_of_bool (get_bool args "include_metrics_overview" false);
    string_of_bool (get_bool args "include_memory_bank" false);
    string_of_bool (get_bool args "include_history_tail" false);
    string_of_bool (get_bool args "include_compaction_history" false);
    string_of_int (get_int args "tail_turns" 3);
    string_of_int (get_int args "tail_messages" 5);
  ] in
  Digest.string (String.concat "|" parts) |> Digest.to_hex

let handle_keeper_status ctx args : tool_result =
  let name = effective_status_name ctx args in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some m) ->
      let args_hash = hash_status_args ctx args in
      (* Cache hit: same updated_at + same args → return cached response *)
      (match Hashtbl.find_opt _cache name with
       | Some entry
         when entry.updated_at = m.updated_at
           && entry.args_hash = args_hash ->
         (true, entry.response)
       | _ ->
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
      let models = Oas_model_resolve.models_of_cascade_name m.cascade_name in
      let primary_max_context = Oas_model_resolve.resolve_max_cascade_context models in
      let base_dir = session_base_dir ctx.config in
         let ctx_opt =
           if include_context then
             let (_session, ctx_opt) =
               load_context_from_checkpoint
                 ~max_checkpoint_messages:m.compaction.max_checkpoint_messages
                 ~trace_id:m.runtime.trace_id
                 ~primary_model_max_tokens:primary_max_context
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
                 ("context_ratio", `Float (Keeper_exec_context.context_ratio c));
                 ("context_tokens", `Int (Keeper_exec_context.token_count c));
                 ("context_max", `Int c.max_tokens);
                 ("message_count", `Int (Keeper_exec_context.message_count c));
               ]
         in
         let keepalive_running = runtime_keepalive_running ctx.config m in
         let agent_status = parse_agent_status ctx.config ~agent_name:m.agent_name in
         let now_ts = Time_compat.now () in
         let created_ts =
           Resilience.Time.parse_iso8601_opt m.created_at |> Option.value ~default:0.0
         in
         let keeper_age_s = if created_ts <= 0.0 then 0.0 else now_ts -. created_ts in
         let last_turn_ago_s = if m.runtime.usage.last_turn_ts <= 0.0 then 0.0 else now_ts -. m.runtime.usage.last_turn_ts in
         let last_handoff_ago_s = if m.runtime.last_handoff_ts <= 0.0 then 0.0 else now_ts -. m.runtime.last_handoff_ts in
         let last_compaction_ago_s = if m.runtime.compaction_rt.last_ts <= 0.0 then 0.0 else now_ts -. m.runtime.compaction_rt.last_ts in
         let last_proactive_ago_s =
           if m.runtime.proactive_rt.last_ts <= 0.0 then 0.0 else now_ts -. m.runtime.proactive_rt.last_ts
         in
         let last_visible_proactive_ago_s =
           if m.runtime.proactive_rt.last_visible_ts <= 0.0 then 0.0
           else now_ts -. m.runtime.proactive_rt.last_visible_ts
         in
         let trace_history_count = List.length m.runtime.trace_history in
         let active_model = active_model_of_meta m in
         let next_model_hint = next_model_hint_of_meta m in
         let runtime_cascade_metrics =
           match Oas_worker.cascade_metrics_json () with
           | `List entries ->
               entries
               |> List.find_opt (function
                    | `Assoc fields ->
                        List.assoc_opt "cascade_name" fields
                        = Some (`String m.cascade_name)
                    | _ -> false)
               |> Option.value ~default:`Null
           | _ -> `Null
         in
         let last_compaction_saved_tokens =
           max 0 (m.runtime.compaction_rt.last_before_tokens - m.runtime.compaction_rt.last_after_tokens)
         in
         let (compact_ratio_gate, compact_message_gate, compact_token_gate) =
           compaction_policy_of_keeper m
         in

         let models_resolved = `List (List.filter_map (fun label ->
           match Llm_provider.Cascade_config.parse_model_string label with
           | None -> None
           | Some cfg ->
             let pricing = Llm_provider.Pricing.pricing_for_model cfg.model_id in
             (* Extract provider name from cascade label prefix.
                Keeper must not reference OAS provider_kind directly. *)
             let provider_name =
               match String.index_opt label ':' with
               | Some idx when idx > 0 ->
                 String.sub label 0 idx |> String.trim |> String.lowercase_ascii
               | _ -> "unknown"
             in
             Some (`Assoc [
               ("provider", `String provider_name);
               ("model_id", `String cfg.model_id);
               ("max_context", `Int (Oas_model_resolve.max_context_of_label label));
               ("max_output_tokens", `Int cfg.max_tokens);
               ("api_key_env", if cfg.api_key <> "" then `String "(set)" else `Null);
               ("cost_per_million_input", `Float pricing.input_per_million);
               ("cost_per_million_output", `Float pricing.output_per_million);
             ])
         ) models) in

         let metrics_store = keeper_metrics_store ctx.config m.name in
         let metrics_path = keeper_metrics_path ctx.config m.name in
         let memory_bank_path = keeper_memory_bank_path ctx.config m.name in
         let session_dir = keeper_session_dir ctx.config m.runtime.trace_id in
         let history_path = keeper_history_path ctx.config m.runtime.trace_id in

         let metrics_tail =
           let lines =
             let dated = Dated_jsonl.read_recent_lines metrics_store tail_turns in
             if dated <> [] then dated
             else read_file_tail_lines metrics_path
                    ~max_bytes:tail_bytes ~max_lines:tail_turns
           in
           `List
             (List.filter_map
                (fun line ->
                  try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None)
                lines)
         in
         let metrics_window_lines =
           if include_metrics_overview then
             let n = max tail_turns 200 in
             let dated = Dated_jsonl.read_recent_lines metrics_store n in
             if dated <> [] then dated
             else read_file_tail_lines metrics_path
                    ~max_bytes:tail_bytes ~max_lines:n
           else
             []
         in
         let metrics_overview =
           if include_metrics_overview then
             summarize_metrics_lines
               metrics_window_lines
               ~default_generation:m.runtime.generation
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
                               Json_util.string_opt_to_json reason );
                           ])
                    | _ -> find_latest tl
                  with Yojson.Json_error _ -> find_latest tl)
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
             let (items_rev, raw_count, fragment_count, filtered_count) =
               List.fold_left
                 (fun (acc, raw_count, fragment_count, filtered_count) line ->
                   try
                     let j = Yojson.Safe.from_string line in
                     let role = Safe_ops.json_string ~default:"unknown" "role" j in
                     let content = Safe_ops.json_string ~default:"" "content" j in
                     let source = Safe_ops.json_string ~default:"unknown" "source" j in
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
                       match source, role_lc with
                       | "direct_user", _ | "direct_assistant", _ ->
                           "direct_conversation"
                       | "world_state_prompt", _ -> "internal_prompt"
                       | "internal_assistant", _ -> "internal_reply"
                       | _, _ ->
                           (match role_lc with
                       | "assistant" -> "self_talk"
                       | "user" -> "input"
                       | "tool" -> "tool_result"
                       | "system" -> "system"
                       | _ -> "other")
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
                         ("source", `String source);
                         ("kind", `String entry_kind);
                         ("is_fragment", `Bool is_fragment);
                         ("ts_unix", `Float ts_unix);
                         ("age_s", Json_util.float_opt_to_json age_s);
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
                   with Yojson.Json_error _ -> (acc, raw_count, fragment_count, filtered_count))
                 ([], 0, 0, 0) lines
             in
             (`List (List.rev items_rev), raw_count, fragment_count, filtered_count)
         in
         let compaction_history_tail =
           if not include_compaction_history then
             (`List [], 0)
           else
             let n = max 200 (tail_compactions * 20) in
             let lines =
               let dated = Dated_jsonl.read_recent_lines metrics_store n in
               if dated <> [] then dated
               else read_file_tail_lines metrics_path
                      ~max_bytes:tail_bytes ~max_lines:n
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
                           ("age_s", Json_util.float_opt_to_json age_s);
                           ("trace_id", `String (Safe_ops.json_string ~default:"" "trace_id" j));
                           ("generation", `Int (Safe_ops.json_int ~default:m.runtime.generation "generation" j));
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
                   with Yojson.Json_error _ -> acc)
                 [] lines
             in
             let events = List.rev events_rev in
             let total = List.length events in
             let start = max 0 (total - tail_compactions) in
             let tail = List.filteri (fun i _ -> i >= start) events in
             (`List tail, total)
        in
        let all_internal_tools =
          keeper_model_tools |> List.map (fun tool -> tool.Types.name)
        in
        let allowed_tools = keeper_allowed_tool_names m in
        let allowed_tool_preview =
          allowed_tools |> List.filteri (fun idx _ -> idx < 10)
        in
        let last_autonomous = String.trim m.runtime.last_autonomous_action_at in
        let tool_audit_snapshot =
          match latest_tool_audit_snapshot_from_files ctx.config ~keeper_name:m.name with
          | Some snapshot ->
              {
                snapshot with
                tool_audit_at =
                  (match snapshot.tool_audit_source, snapshot.tool_audit_at with
                   | Some _, None when last_autonomous <> "" -> Some last_autonomous
                   | Some _, None -> Some m.updated_at
                   | _ -> snapshot.tool_audit_at);
              }
          | None ->
              let has_runtime_activity =
                last_autonomous <> ""
                || m.runtime.autonomous_turn_count > 0
                || m.runtime.autonomous_action_count > 0
              in
              {
                empty_tool_audit_snapshot with
                latest_tool_call_count =
                  (if has_runtime_activity then Some 0 else None);
                latest_action_source = None;
                tool_audit_source =
                  (if has_runtime_activity then Some "keeper_runtime_meta" else None);
                tool_audit_at =
                  (if last_autonomous <> "" then Some last_autonomous
                   else if has_runtime_activity then Some m.updated_at
                   else None);
              }
        in
        let blocked_internal_tools =
          all_internal_tools
          |> List.filter (fun name -> not (List.mem name allowed_tools))
        in
        let tool_preset = Keeper_types.tool_access_preset m.tool_access in
        let tool_also_allow = Keeper_types.tool_access_also_allowlist m.tool_access in
        let tool_custom_allowlist =
          Keeper_types.tool_access_custom_allowlist m.tool_access
          |> Option.value ~default:[]
        in

         let json = `Assoc [
           ("name", `String name);
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
           ("will", if String.trim m.will = "" then `Null else `String m.will);
           ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
           ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
           ("self_model", `Assoc [
             ("will", if String.trim m.will = "" then `Null else `String m.will);
             ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
             ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
           ]);
           ("paused", `Bool m.paused);
           ("keepalive_running", `Bool keepalive_running);
           ("agent", agent_status);
           ("keeper_age_s", `Float keeper_age_s);
           ("last_turn_ago_s", `Float last_turn_ago_s);
           ("last_handoff_ago_s", `Float last_handoff_ago_s);
           ("last_compaction_ago_s", `Float last_compaction_ago_s);
           ("last_proactive_ago_s", `Float last_proactive_ago_s);
           ("last_visible_proactive_ago_s", `Float last_visible_proactive_ago_s);
           ("active_model", `String active_model);
           ("next_model_hint", Json_util.string_opt_to_json next_model_hint);
           ("runtime_cascade_metrics", runtime_cascade_metrics);
           ("trace_history_count", `Int trace_history_count);
           ("handoff_count_total", `Int trace_history_count);
           ("last_compaction_saved_tokens", `Int last_compaction_saved_tokens);
           ("allowed_tool_count", `Int (List.length allowed_tools));
           ("tool_policy_mode",
             `String
               (match Keeper_types.tool_access_custom_allowlist m.tool_access with
                | Some _ -> "custom"
                | None -> "preset"));
           ("tool_preset",
             match tool_preset with
             | Some preset -> `String (Keeper_types.tool_preset_to_string preset)
             | None -> `Null);
           ("tool_also_allow", string_list_to_json tool_also_allow);
           ("tool_custom_allowlist", string_list_to_json tool_custom_allowlist);
           ("tool_denylist", string_list_to_json m.tool_denylist);
           ("allowed_tool_names", string_list_to_json allowed_tools);
           ("allowed_tool_preview", string_list_to_json allowed_tool_preview);
           ("latest_tool_names",
             string_list_to_json tool_audit_snapshot.latest_tool_names);
           ("latest_tool_call_count",
             Json_util.int_opt_to_json tool_audit_snapshot.latest_tool_call_count);
           ("latest_action_source",
             Json_util.string_opt_to_json tool_audit_snapshot.latest_action_source);
           ("tool_audit_source",
             Json_util.string_opt_to_json tool_audit_snapshot.tool_audit_source);
           ("tool_audit_at",
             Json_util.string_opt_to_json tool_audit_snapshot.tool_audit_at);
           ("lifecycle", `Assoc [
             ("created_at", `String m.created_at);
             ("updated_at", `String m.updated_at);
             ("uptime_hours", `Float (keeper_age_s /. 3600.0));
           ]);
           ("proactive", `Assoc [
             ("enabled", `Bool m.proactive.enabled);
             ("idle_sec", `Int m.proactive.idle_sec);
             ("cooldown_sec", `Int m.proactive.cooldown_sec);
             ("count_total", `Int m.runtime.proactive_rt.count_total);
             ("visible_count_total", `Int m.runtime.proactive_rt.visible_count_total);
             ("last_ts", `Float m.runtime.proactive_rt.last_ts);
             ("last_ago_s", `Float last_proactive_ago_s);
             ("last_visible_ts", `Float m.runtime.proactive_rt.last_visible_ts);
             ("last_visible_ago_s", `Float last_visible_proactive_ago_s);
             ( "last_outcome"
             , `String
                 (proactive_cycle_outcome_to_string
                    m.runtime.proactive_rt.last_outcome) );
             ("last_reason",
               if String.trim m.runtime.proactive_rt.last_reason = ""
               then `Null
               else `String m.runtime.proactive_rt.last_reason);
             ("last_preview",
               if String.trim m.runtime.proactive_rt.last_preview = ""
               then `Null
               else `String m.runtime.proactive_rt.last_preview);
           ]);
           ("drift", drift_surface_json ());
           ("policy", `Assoc [
             ("voice_tools_available", `Bool (List.mem "keeper_voice_speak" allowed_tools));
             ("allowed_paths", string_list_to_json m.allowed_paths);
           ("allowed_tools", string_list_to_json allowed_tools);
            ("available_internal_tools", string_list_to_json all_internal_tools);
            ("blocked_internal_tools", string_list_to_json blocked_internal_tools);
           ]);
           ("auto_team_session", auto_team_session_surface_json ());
           ("auto_team_session_enabled", `Bool false);
           ("autonomy", `Assoc [
             ("turn_count", `Int m.runtime.autonomous_turn_count);
             ("tool_turn_count", `Int m.runtime.autonomous_tool_turn_count);
             ("text_turn_count", `Int m.runtime.autonomous_text_turn_count);
             ("board_reactive_turn_count", `Int m.runtime.board_reactive_turn_count);
             ("mention_reactive_turn_count", `Int m.runtime.mention_reactive_turn_count);
             ("noop_turn_count", `Int m.runtime.noop_turn_count);
             ("tool_action_count", `Int m.runtime.autonomous_action_count);
           ]);
           ("social", `Assoc [
             ("model", `String m.social_model);
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
          ]);
           ("compaction_policy", `Assoc [
             ("profile", `String m.compaction.profile);
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
           ("runtime", runtime_surface_json ctx.config m);
           ("coordination", coordination_surface_json m);
           ("sources", source_provenance_json ctx.config m);
           ("context", ctx_stats);
           ("skill_route", Json_util.option_to_yojson Fun.id last_skill_route);
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
             ("metrics", `String (Dated_jsonl.base_dir metrics_store));
             ("metrics_single_file", `String metrics_path);
             ("memory_bank", `String memory_bank_path);
             ("decisions", `String (keeper_decision_log_path ctx.config m.name));
             ("policy", `String (keeper_policy_log_path ctx.config m.name));
             ("feedback", `String (keeper_feedback_log_path ctx.config m.name));
             ("dataset_export", `String (keeper_dataset_export_path ctx.config m.name));
             ("session_dir", `String session_dir);
             ("history", `String history_path);
             ("evidence_dir", `String
               (Filename.concat ctx.config.base_path
                 (Printf.sprintf ".masc/evidence/%s/%s"
                   (Room_utils.safe_filename m.name)
                   (Room_utils.safe_filename m.runtime.trace_id))));
           ]);
           ("execution_context", `Assoc [
             ("playground_path", `String
               (Keeper_alerting_path.playground_path_of_keeper m.name));
             ("execution_scope", `String m.execution_scope);
             ("allowed_paths", string_list_to_json m.allowed_paths);
             ("last_evidence",
               match Keeper_evidence.latest_evidence
                 ~base_path:ctx.config.base_path
                 ~keeper_name:m.name
                 ~trace_id:m.runtime.trace_id with
               | Some ev -> ev
               | None -> `Null);
             ("evidence_chain_valid",
               match Keeper_evidence.verify_evidence_chain
                 ~base_path:ctx.config.base_path
                 ~keeper_name:m.name
                 ~trace_id:m.runtime.trace_id with
               | Ok () -> `Bool true
               | Error _ -> `Bool false);
           ]);
         ] in
         let response = Yojson.Safe.pretty_to_string json in
         Hashtbl.replace _cache name
           { updated_at = m.updated_at; args_hash; response };
         (true, response))
