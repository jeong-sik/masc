(** Dashboard_http_keeper_detail — metrics window computation for keeper dashboard.
    Extracts the metrics series iteration loop from keepers_dashboard_json. *)

include Dashboard_http_keeper_metrics

type metrics_acc =
  { ma_handoff_count : int
  ; ma_compaction_events : int
  ; ma_compaction_saved_tokens : int
  ; ma_compaction_before_tokens : int
  ; ma_fallback_count : int
  ; ma_proactive_fallback_count : int
  ; ma_tool_call_count : int
  ; ma_turn_points : int
  ; ma_heartbeat_points : int
  ; ma_proactive_points : int
  ; ma_drift_applied_count : int
  ; ma_auto_reflect_count : int
  ; ma_auto_plan_count : int
  ; ma_auto_compact_count : int
  ; ma_auto_handoff_count : int
  ; ma_guardrail_stop_count : int
  ; ma_repetition_risk_sum : float
  ; ma_repetition_risk_points : int
  ; ma_goal_alignment_sum : float
  ; ma_goal_alignment_points : int
  ; ma_response_alignment_sum : float
  ; ma_response_alignment_points : int
  ; ma_goal_drift_sum : float
  ; ma_goal_drift_points : int
  ; ma_memory_checks : int
  ; ma_memory_passed : int
  ; ma_memory_corrections : int
  ; ma_memory_correction_success : int
  ; ma_memory_score_sum : float
  ; ma_memory_weather_checks : int
  ; ma_memory_weather_passed : int
  ; ma_memory_threshold : float
  ; ma_memory_notes_added : int
  ; ma_memory_compaction_events : int
  ; ma_memory_compaction_before_notes : int
  ; ma_memory_compaction_dropped_notes : int
  ; ma_memory_compaction_invalid_dropped : int
  ; ma_proactive_previews_rev : string list
  ; ma_last_handoff : Yojson.Safe.t option
  ; ma_last_compaction : Yojson.Safe.t option
  }

let init_acc =
  { ma_handoff_count = 0
  ; ma_compaction_events = 0
  ; ma_compaction_saved_tokens = 0
  ; ma_compaction_before_tokens = 0
  ; ma_fallback_count = 0
  ; ma_proactive_fallback_count = 0
  ; ma_tool_call_count = 0
  ; ma_turn_points = 0
  ; ma_heartbeat_points = 0
  ; ma_proactive_points = 0
  ; ma_drift_applied_count = 0
  ; ma_auto_reflect_count = 0
  ; ma_auto_plan_count = 0
  ; ma_auto_compact_count = 0
  ; ma_auto_handoff_count = 0
  ; ma_guardrail_stop_count = 0
  ; ma_repetition_risk_sum = 0.0
  ; ma_repetition_risk_points = 0
  ; ma_goal_alignment_sum = 0.0
  ; ma_goal_alignment_points = 0
  ; ma_response_alignment_sum = 0.0
  ; ma_response_alignment_points = 0
  ; ma_goal_drift_sum = 0.0
  ; ma_goal_drift_points = 0
  ; ma_memory_checks = 0
  ; ma_memory_passed = 0
  ; ma_memory_corrections = 0
  ; ma_memory_correction_success = 0
  ; ma_memory_score_sum = 0.0
  ; ma_memory_weather_checks = 0
  ; ma_memory_weather_passed = 0
  ; ma_memory_threshold = 0.18
  ; ma_memory_notes_added = 0
  ; ma_memory_compaction_events = 0
  ; ma_memory_compaction_before_notes = 0
  ; ma_memory_compaction_dropped_notes = 0
  ; ma_memory_compaction_invalid_dropped = 0
  ; ma_proactive_previews_rev = []
  ; ma_last_handoff = None
  ; ma_last_compaction = None
  }
;;

let compute_metrics_window
      ~(parsed_metrics : Yojson.Safe.t list)
      ~(generation : int)
      ~(compact : bool)
      ~(series_points : int)
      ~(metrics_window_max_bytes : int)
      ~(primary_model_norm : string)
      ~(primary_model : string)
  : Yojson.Safe.t list * Yojson.Safe.t * Yojson.Safe.t option * Yojson.Safe.t option
  =
  let open Yojson.Safe.Util in
  let work_kind_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let model_counts_window : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let tool_counts_window : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let memory_kind_counts_window : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let drift_reason_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let compaction_trigger_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let generation_stats : (int, keeper_gen_window_stats) Hashtbl.t = Hashtbl.create 8 in
  let acc, items_rev =
    List.fold_left
      (fun (acc, items) j ->
         try
           let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
           let ratio = Safe_ops.json_float ~default:0.0 "context_ratio" j in
           let tokens = Safe_ops.json_int ~default:0 "context_tokens" j in
           let context_max = Safe_ops.json_int ~default:0 "context_max" j in
           let channel = Safe_ops.json_string ~default:"turn" "channel" j in
           let is_turn = channel = "turn" in
           let is_heartbeat = channel = "heartbeat" in
           let is_scheduled_autonomous =
             channel = "scheduled_autonomous" || channel = "proactive"
           in
           let is_interaction = is_turn || is_scheduled_autonomous in
           let compacted = Safe_ops.json_bool ~default:false "compacted" j in
           let gen = Safe_ops.json_int ~default:generation "generation" j in
           let trace_id = Safe_ops.json_string ~default:"" "trace_id" j in
           let before_tokens =
             Safe_ops.json_int ~default:0 "compaction_before_tokens" j
           in
           let after_tokens = Safe_ops.json_int ~default:0 "compaction_after_tokens" j in
           let saved_tokens = max 0 (before_tokens - after_tokens) in
           let compaction_trigger_now =
             Safe_ops.json_string_opt "compaction_trigger" j
             |> Option.map String.trim
             |> function
             | Some s when s <> "" -> Some s
             | _ -> None
           in
           let handoff_obj = j |> member "handoff" in
           let handoff_performed =
             Safe_ops.json_bool ~default:false "performed" handoff_obj
           in
           let handoff_to_model = Safe_ops.json_string_opt "to_model" handoff_obj in
           let handoff_prev_trace_id =
             Safe_ops.json_string_opt "prev_trace_id" handoff_obj
           in
           let handoff_new_trace_id =
             Safe_ops.json_string_opt "new_trace_id" handoff_obj
           in
           let handoff_new_generation =
             match Safe_ops.json_int_opt "new_generation" handoff_obj with
             | Some value -> Some value
             | None -> Safe_ops.json_int_opt "to_generation" handoff_obj
           in
           let usage_obj = j |> member "usage" in
           let input_tokens = Safe_ops.json_int_opt "input_tokens" usage_obj in
           let output_tokens = Safe_ops.json_int_opt "output_tokens" usage_obj in
           let total_tokens = Safe_ops.json_int_opt "total_tokens" usage_obj in
           let latency_ms = Safe_ops.json_int ~default:0 "latency_ms" j in
           let cost_usd = Safe_ops.json_float_opt "cost_usd" j in
           let model_used = Safe_ops.json_string ~default:"" "model_used" j in
           let message_count = Safe_ops.json_int ~default:0 "message_count" j in
           let model_used_norm = normalize_model_name model_used in
           let model_bucket =
             if model_used_norm <> "" then model_used_norm else model_used
           in
           let work_kind_raw =
             Keeper_unified_metrics.work_kind_of_json j |> Option.value ~default:""
           in
           let memory_check = j |> member "memory_check" in
           let memory_performed =
             Safe_ops.json_bool ~default:false "performed" memory_check
           in
           let memory_query_kind =
             Safe_ops.json_string ~default:"none" "query_kind" memory_check
           in
           let memory_passed_now =
             Safe_ops.json_bool ~default:false "passed" memory_check
           in
           let memory_final_score =
             Safe_ops.json_float ~default:0.0 "final_score" memory_check
           in
           let memory_threshold_now =
             Safe_ops.json_float ~default:0.18 "threshold" memory_check
           in
           let memory_correction_applied_now =
             Safe_ops.json_bool ~default:false "correction_applied" memory_check
           in
           let memory_correction_success_now =
             Safe_ops.json_bool ~default:false "correction_success" memory_check
           in
           let memory_expected_topic =
             Safe_ops.json_string_opt "expected_topic" memory_check
           in
           let proactive_obj = j |> member "proactive" in
           let proactive_fallback_applied_now =
             Safe_ops.json_bool ~default:false "fallback_applied" proactive_obj
           in
           let proactive_preview_now =
             Safe_ops.json_string_opt "preview" proactive_obj
             |> Option.map String.trim
             |> function
             | Some s when s <> "" -> Some s
             | _ -> None
           in
           let drift_obj = j |> member "drift" in
           let drift_applied_now =
             Safe_ops.json_bool ~default:false "applied" drift_obj
           in
           let drift_reason_now =
             Safe_ops.json_string_opt "reason" drift_obj
             |> Option.map String.trim
             |> function
             | Some s when s <> "" -> Some s
             | _ -> None
           in
           let auto_rules_obj = j |> member "auto_rules" in
           let auto_reflect_now =
             Safe_ops.json_bool
               ~default:(Safe_ops.json_bool ~default:false "reflect" auto_rules_obj)
               "auto_reflect"
               j
           in
           let auto_plan_now =
             Safe_ops.json_bool
               ~default:(Safe_ops.json_bool ~default:false "plan" auto_rules_obj)
               "auto_plan"
               j
           in
           let auto_compact_now =
             Safe_ops.json_bool
               ~default:(Safe_ops.json_bool ~default:false "compact" auto_rules_obj)
               "auto_compact"
               j
           in
           let auto_handoff_now =
             Safe_ops.json_bool
               ~default:(Safe_ops.json_bool ~default:false "handoff" auto_rules_obj)
               "auto_handoff"
               j
           in
           let guardrail_stop_now =
             Safe_ops.json_bool
               ~default:
                 (Safe_ops.json_bool ~default:false "guardrail_stop" auto_rules_obj)
               "guardrail_stop"
               j
           in
           let repetition_risk_opt = Safe_ops.json_float_opt "repetition_risk" j in
           let goal_alignment_opt = Safe_ops.json_float_opt "goal_alignment" j in
           let response_alignment_opt = Safe_ops.json_float_opt "response_alignment" j in
           let goal_drift_opt = Safe_ops.json_float_opt "goal_drift" j in
           let memory_notes_added_now =
             Safe_ops.json_int ~default:0 "memory_notes_added" j
           in
           let memory_top_kind_now = Safe_ops.json_string_opt "memory_top_kind" j in
           let memory_note_kinds =
             match j |> member "memory_note_kinds" with
             | `List xs ->
               List.filter_map
                 (function
                   | `String s when String.trim s <> "" -> Some (String.trim s)
                   | _ -> None)
                 xs
             | _ -> []
           in
           let memory_compaction_performed_now =
             Safe_ops.json_bool ~default:false "memory_compaction_performed" j
           in
           let memory_compaction_before_notes_now =
             Safe_ops.json_int ~default:0 "memory_compaction_before_notes" j
           in
           let memory_compaction_dropped_notes_now =
             Safe_ops.json_int ~default:0 "memory_compaction_dropped_notes" j
           in
           let memory_compaction_invalid_dropped_now =
             Safe_ops.json_int ~default:0 "memory_compaction_invalid_dropped" j
           in
           let tools_used =
             match j |> member "tools_used" with
             | `List xs ->
               List.filter_map
                 (function
                   | `String s when String.trim s <> "" -> Some s
                   | _ -> None)
                 xs
             | _ -> []
           in
           let tool_call_count_now =
             Safe_ops.json_int ~default:(List.length tools_used) "tool_call_count" j
           in
           let memory_is_weather =
             match memory_expected_topic with
             | Some "weather" -> true
             | _ -> false
           in
           let work_kind =
             if work_kind_raw <> ""
             then work_kind_raw
             else if memory_performed
             then
               if memory_query_kind <> "" && memory_query_kind <> "none"
               then memory_query_kind
               else "memory_recall"
             else (
               match memory_expected_topic with
               | Some "weather" -> "weather_answer"
               | Some "first_question" -> "first_question_answer"
               | Some topic when topic <> "" -> topic
               | _ -> "general_chat")
           in
           let acc =
             if handoff_performed
             then (
               let acc =
                 if is_interaction
                 then { acc with ma_handoff_count = acc.ma_handoff_count + 1 }
                 else acc
               in
               { acc with
                 ma_last_handoff =
                   Some
                     (`Assoc
                         [ "ts_unix", `Float ts_unix
                         ; "trace_id", `String trace_id
                         ; "generation", `Int gen
                         ; ( "to_model"
                           , Json_util.string_opt_to_json
                               (match handoff_to_model with
                                | Some s when s <> "" -> Some s
                                | _ -> None) )
                         ; ( "prev_trace_id"
                           , Json_util.string_opt_to_json
                               (match handoff_prev_trace_id with
                                | Some s when s <> "" -> Some s
                                | _ -> None) )
                         ; ( "new_trace_id"
                           , Json_util.string_opt_to_json
                               (match handoff_new_trace_id with
                                | Some s when s <> "" -> Some s
                                | _ -> None) )
                         ; ( "new_generation"
                           , Json_util.int_opt_to_json handoff_new_generation )
                         ])
               })
             else acc
           in
           let acc =
             if compacted
             then (
               let acc =
                 if is_interaction
                 then (
                   (match compaction_trigger_now with
                    | Some reason -> count_table_incr compaction_trigger_counts reason
                    | None -> ());
                   { acc with
                     ma_compaction_events = acc.ma_compaction_events + 1
                   ; ma_compaction_saved_tokens =
                       acc.ma_compaction_saved_tokens + saved_tokens
                   ; ma_compaction_before_tokens =
                       acc.ma_compaction_before_tokens + before_tokens
                   })
                 else acc
               in
               { acc with
                 ma_last_compaction =
                   Some
                     (`Assoc
                         [ "ts_unix", `Float ts_unix
                         ; "trace_id", `String trace_id
                         ; "generation", `Int gen
                         ; "before_tokens", `Int before_tokens
                         ; "after_tokens", `Int after_tokens
                         ; "saved_tokens", `Int saved_tokens
                         ; "trigger", Json_util.string_opt_to_json compaction_trigger_now
                         ])
               })
             else acc
           in
           let acc =
             if
               is_interaction
               && primary_model_norm <> ""
               && model_used_norm <> ""
               && model_used_norm <> primary_model_norm
             then { acc with ma_fallback_count = acc.ma_fallback_count + 1 }
             else acc
           in
           let acc =
             if is_turn then { acc with ma_turn_points = acc.ma_turn_points + 1 } else acc
           in
           let acc =
             if is_scheduled_autonomous
             then { acc with ma_proactive_points = acc.ma_proactive_points + 1 }
             else acc
           in
           let acc =
             if is_scheduled_autonomous && proactive_fallback_applied_now
             then
               { acc with
                 ma_proactive_fallback_count = acc.ma_proactive_fallback_count + 1
               }
             else acc
           in
           let acc =
             if is_scheduled_autonomous
             then (
               match proactive_preview_now with
               | Some preview ->
                 { acc with
                   ma_proactive_previews_rev = preview :: acc.ma_proactive_previews_rev
                 }
               | None -> acc)
             else acc
           in
           let acc =
             if is_interaction
             then (
               let acc =
                 if auto_reflect_now
                 then { acc with ma_auto_reflect_count = acc.ma_auto_reflect_count + 1 }
                 else acc
               in
               let acc =
                 if auto_plan_now
                 then { acc with ma_auto_plan_count = acc.ma_auto_plan_count + 1 }
                 else acc
               in
               let acc =
                 if auto_compact_now
                 then { acc with ma_auto_compact_count = acc.ma_auto_compact_count + 1 }
                 else acc
               in
               let acc =
                 if auto_handoff_now
                 then { acc with ma_auto_handoff_count = acc.ma_auto_handoff_count + 1 }
                 else acc
               in
               let acc =
                 if guardrail_stop_now
                 then
                   { acc with ma_guardrail_stop_count = acc.ma_guardrail_stop_count + 1 }
                 else acc
               in
               let acc =
                 match repetition_risk_opt with
                 | Some v ->
                   { acc with
                     ma_repetition_risk_sum = acc.ma_repetition_risk_sum +. v
                   ; ma_repetition_risk_points = acc.ma_repetition_risk_points + 1
                   }
                 | None -> acc
               in
               let acc =
                 match goal_alignment_opt with
                 | Some v ->
                   { acc with
                     ma_goal_alignment_sum = acc.ma_goal_alignment_sum +. v
                   ; ma_goal_alignment_points = acc.ma_goal_alignment_points + 1
                   }
                 | None -> acc
               in
               let acc =
                 match response_alignment_opt with
                 | Some v ->
                   { acc with
                     ma_response_alignment_sum = acc.ma_response_alignment_sum +. v
                   ; ma_response_alignment_points = acc.ma_response_alignment_points + 1
                   }
                 | None -> acc
               in
               let acc =
                 match goal_drift_opt with
                 | Some v ->
                   { acc with
                     ma_goal_drift_sum = acc.ma_goal_drift_sum +. v
                   ; ma_goal_drift_points = acc.ma_goal_drift_points + 1
                   }
                 | None -> acc
               in
               let acc =
                 if drift_applied_now
                 then (
                   (match drift_reason_now with
                    | Some reason -> count_table_incr drift_reason_counts reason
                    | None -> ());
                   { acc with ma_drift_applied_count = acc.ma_drift_applied_count + 1 })
                 else acc
               in
               count_table_incr work_kind_counts work_kind;
               count_table_incr model_counts_window model_bucket;
               List.iter (count_table_incr tool_counts_window) tools_used;
               let acc =
                 { acc with
                   ma_tool_call_count = acc.ma_tool_call_count + tool_call_count_now
                 ; ma_memory_notes_added =
                     acc.ma_memory_notes_added + memory_notes_added_now
                 }
               in
               let acc =
                 if memory_compaction_performed_now
                 then
                   { acc with
                     ma_memory_compaction_events = acc.ma_memory_compaction_events + 1
                   ; ma_memory_compaction_before_notes =
                       acc.ma_memory_compaction_before_notes
                       + memory_compaction_before_notes_now
                   ; ma_memory_compaction_dropped_notes =
                       acc.ma_memory_compaction_dropped_notes
                       + memory_compaction_dropped_notes_now
                   ; ma_memory_compaction_invalid_dropped =
                       acc.ma_memory_compaction_invalid_dropped
                       + memory_compaction_invalid_dropped_now
                   }
                 else acc
               in
               List.iter (count_table_incr memory_kind_counts_window) memory_note_kinds;
               if memory_note_kinds = []
               then (
                 match memory_top_kind_now with
                 | Some kind when String.trim kind <> "" ->
                   count_table_incr memory_kind_counts_window kind
                 | Some _ | None -> ());
               let acc =
                 if memory_performed
                 then (
                   let acc =
                     { acc with
                       ma_memory_checks = acc.ma_memory_checks + 1
                     ; ma_memory_score_sum = acc.ma_memory_score_sum +. memory_final_score
                     ; ma_memory_threshold = memory_threshold_now
                     ; ma_memory_passed =
                         (acc.ma_memory_passed + if memory_passed_now then 1 else 0)
                     ; ma_memory_corrections =
                         (acc.ma_memory_corrections
                          + if memory_correction_applied_now then 1 else 0)
                     ; ma_memory_correction_success =
                         (acc.ma_memory_correction_success
                          + if memory_correction_success_now then 1 else 0)
                     }
                   in
                   if memory_is_weather
                   then
                     { acc with
                       ma_memory_weather_checks = acc.ma_memory_weather_checks + 1
                     ; ma_memory_weather_passed =
                         (acc.ma_memory_weather_passed
                          + if memory_passed_now then 1 else 0)
                     }
                   else acc)
                 else acc
               in
               let gen_stats =
                 match Hashtbl.find_opt generation_stats gen with
                 | Some gs -> gs
                 | None ->
                   let gs = create_keeper_gen_window_stats () in
                   Hashtbl.add generation_stats gen gs;
                   gs
               in
               gen_stats.turns <- gen_stats.turns + 1;
               gen_stats.input_tokens
               <- gen_stats.input_tokens + Option.value ~default:0 input_tokens;
               gen_stats.output_tokens
               <- gen_stats.output_tokens + Option.value ~default:0 output_tokens;
               gen_stats.total_tokens
               <- gen_stats.total_tokens + Option.value ~default:0 total_tokens;
               if handoff_performed then gen_stats.handoffs <- gen_stats.handoffs + 1;
               if compacted then gen_stats.compactions <- gen_stats.compactions + 1;
               if memory_compaction_performed_now
               then (
                 gen_stats.memory_compactions <- gen_stats.memory_compactions + 1;
                 gen_stats.memory_trimmed
                 <- gen_stats.memory_trimmed + memory_compaction_dropped_notes_now);
               if memory_performed
               then (
                 gen_stats.memory_checks <- gen_stats.memory_checks + 1;
                 if memory_passed_now
                 then gen_stats.memory_passed <- gen_stats.memory_passed + 1);
               gen_stats.memory_notes <- gen_stats.memory_notes + memory_notes_added_now;
               if gen_stats.first_ts <= 0.0 || ts_unix < gen_stats.first_ts
               then gen_stats.first_ts <- ts_unix;
               if ts_unix > gen_stats.last_ts then gen_stats.last_ts <- ts_unix;
               count_table_incr gen_stats.models model_bucket;
               List.iter (count_table_incr gen_stats.tools) tools_used;
               acc)
             else acc
           in
           let acc =
             if is_heartbeat
             then { acc with ma_heartbeat_points = acc.ma_heartbeat_points + 1 }
             else acc
           in
           let output_item =
             if compact
             then None
             else
               Some
                 (`Assoc
                     [ "ts_unix", `Float ts_unix
                     ; "trace_id", `String trace_id
                     ; "channel", `String channel
                     ; "context_ratio", `Float ratio
                     ; "context_tokens", `Int tokens
                     ; "context_max", `Int context_max
                     ; "message_count", `Int message_count
                     ; "compacted", `Bool compacted
                     ; "handoff_performed", `Bool handoff_performed
                     ; ( "handoff"
                       , if handoff_performed
                         then
                           `Assoc
                             [ "performed", `Bool true
                             ; ( "to_model"
                               , match handoff_to_model with
                                 | Some s when s <> "" -> `String s
                                 | _ -> `Null )
                             ; ( "prev_trace_id"
                               , match handoff_prev_trace_id with
                                 | Some s when s <> "" -> `String s
                                 | _ -> `Null )
                             ; ( "new_trace_id"
                               , match handoff_new_trace_id with
                                 | Some s when s <> "" -> `String s
                                 | _ -> `Null )
                             ; ( "new_generation"
                               , match handoff_new_generation with
                                 | Some g -> `Int g
                                 | None -> `Null )
                             ; ( "to_generation"
                               , match handoff_new_generation with
                                 | Some g -> `Int g
                                 | None -> `Null )
                             ]
                         else `Null )
                     ; ( "handoff_to_model"
                       , Json_util.string_opt_to_json
                           (match handoff_to_model with
                            | Some s when s <> "" -> Some s
                            | _ -> None) )
                     ; ( "handoff_prev_trace_id"
                       , Json_util.string_opt_to_json
                           (match handoff_prev_trace_id with
                            | Some s when s <> "" -> Some s
                            | _ -> None) )
                     ; ( "handoff_new_trace_id"
                       , Json_util.string_opt_to_json
                           (match handoff_new_trace_id with
                            | Some s when s <> "" -> Some s
                            | _ -> None) )
                     ; ( "handoff_new_generation"
                       , Json_util.int_opt_to_json handoff_new_generation )
                     ; "generation", `Int gen
                     ; "input_tokens", Json_util.int_opt_to_json input_tokens
                     ; "output_tokens", Json_util.int_opt_to_json output_tokens
                     ; "total_tokens", Json_util.int_opt_to_json total_tokens
                     ; "latency_ms", `Int latency_ms
                     ; "cost_usd", Json_util.float_opt_to_json cost_usd
                     ; "model_used", `String model_used
                     ; "prompt_fingerprint", j |> member "prompt_fingerprint"
                     ; "prompt", j |> member "prompt"
                     ; "compaction_before_tokens", `Int before_tokens
                     ; "compaction_after_tokens", `Int after_tokens
                     ; "compaction_saved_tokens", `Int saved_tokens
                     ; ( "compaction_trigger"
                       , Json_util.string_opt_to_json compaction_trigger_now )
                     ; "work_kind", `String work_kind
                     ; "tool_call_count", `Int tool_call_count_now
                     ; "tools_used", `List (List.map (fun s -> `String s) tools_used)
                     ; "proactive_fallback_applied", `Bool proactive_fallback_applied_now
                     ; ( "proactive_preview"
                       , Json_util.string_opt_to_json proactive_preview_now )
                     ; "drift_applied", `Bool drift_applied_now
                     ; "drift_reason", Json_util.string_opt_to_json drift_reason_now
                     ; "auto_reflect", `Bool auto_reflect_now
                     ; "auto_plan", `Bool auto_plan_now
                     ; "auto_compact", `Bool auto_compact_now
                     ; "auto_handoff", `Bool auto_handoff_now
                     ; "guardrail_stop", `Bool guardrail_stop_now
                     ; "repetition_risk", Json_util.float_opt_to_json repetition_risk_opt
                     ; "goal_alignment", Json_util.float_opt_to_json goal_alignment_opt
                     ; ( "response_alignment"
                       , Json_util.float_opt_to_json response_alignment_opt )
                     ; "goal_drift", Json_util.float_opt_to_json goal_drift_opt
                     ; "reflection", j |> member "reflection"
                     ; "memory_performed", `Bool memory_performed
                     ; "memory_query_kind", `String memory_query_kind
                     ; "memory_passed", `Bool memory_passed_now
                     ; "memory_final_score", `Float memory_final_score
                     ; "memory_threshold", `Float memory_threshold_now
                     ; "memory_correction_applied", `Bool memory_correction_applied_now
                     ; "memory_correction_success", `Bool memory_correction_success_now
                     ; "memory_notes_added", `Int memory_notes_added_now
                     ; ( "memory_top_kind"
                       , Json_util.string_opt_to_json
                           (match memory_top_kind_now with
                            | Some s when String.trim s <> "" -> Some s
                            | _ -> None) )
                     ; ( "memory_note_kinds"
                       , `List (List.map (fun s -> `String s) memory_note_kinds) )
                     ; ( "memory_compaction_performed"
                       , `Bool memory_compaction_performed_now )
                     ; ( "memory_compaction_before_notes"
                       , `Int memory_compaction_before_notes_now )
                     ; ( "memory_compaction_dropped_notes"
                       , `Int memory_compaction_dropped_notes_now )
                     ; ( "memory_compaction_invalid_dropped"
                       , `Int memory_compaction_invalid_dropped_now )
                     ; ( "memory_expected_topic"
                       , Json_util.string_opt_to_json memory_expected_topic )
                     ; "timeout_budget", j |> member "timeout_budget"
                     ; "inference_telemetry", j |> member "inference_telemetry"
                     ])
           in
           match output_item with
           | Some i -> acc, i :: items
           | None -> acc, items
         with
         | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> acc, items)
      (init_acc, [])
      parsed_metrics
  in
  let items = List.rev items_rev in
  let sample_points = List.length items in
  let turn_points_int = acc.ma_turn_points in
  let proactive_points_int = acc.ma_proactive_points in
  let interaction_points_int = turn_points_int + proactive_points_int in
  let fallback_rate =
    if interaction_points_int = 0
    then 0.0
    else float_of_int acc.ma_fallback_count /. float_of_int interaction_points_int
  in
  let proactive_fallback_rate =
    if proactive_points_int = 0
    then 0.0
    else float_of_int acc.ma_proactive_fallback_count /. float_of_int proactive_points_int
  in
  let intervention_share =
    if interaction_points_int = 0
    then 0.0
    else float_of_int proactive_points_int /. float_of_int interaction_points_int
  in
  let intervention_per_turn =
    if turn_points_int = 0
    then 0.0
    else float_of_int proactive_points_int /. float_of_int turn_points_int
  in
  let drift_applied_rate =
    if interaction_points_int = 0
    then 0.0
    else float_of_int acc.ma_drift_applied_count /. float_of_int interaction_points_int
  in
  let auto_reflect_rate =
    if interaction_points_int = 0
    then 0.0
    else float_of_int acc.ma_auto_reflect_count /. float_of_int interaction_points_int
  in
  let auto_plan_rate =
    if interaction_points_int = 0
    then 0.0
    else float_of_int acc.ma_auto_plan_count /. float_of_int interaction_points_int
  in
  let auto_compact_rate =
    if interaction_points_int = 0
    then 0.0
    else float_of_int acc.ma_auto_compact_count /. float_of_int interaction_points_int
  in
  let auto_handoff_rate =
    if interaction_points_int = 0
    then 0.0
    else float_of_int acc.ma_auto_handoff_count /. float_of_int interaction_points_int
  in
  let guardrail_stop_rate =
    if interaction_points_int = 0
    then 0.0
    else float_of_int acc.ma_guardrail_stop_count /. float_of_int interaction_points_int
  in
  let proactive_previews = List.rev acc.ma_proactive_previews_rev in
  let proactive_similarity_warn_threshold = 0.90 in
  let proactive_similarity_window = 8 in
  let ( proactive_preview_sample_count
      , proactive_preview_pair_count
      , proactive_preview_similarity_avg
      , proactive_preview_similarity_max
      , proactive_preview_similarity_warn )
    =
    proactive_preview_similarity_stats
      ~window:proactive_similarity_window
      ~warn_threshold:proactive_similarity_warn_threshold
      proactive_previews
  in
  let compaction_saved_ratio =
    if acc.ma_compaction_before_tokens = 0
    then 0.0
    else
      float_of_int acc.ma_compaction_saved_tokens
      /. float_of_int acc.ma_compaction_before_tokens
  in
  let avg_compaction_saved_tokens =
    if acc.ma_compaction_events = 0
    then 0.0
    else
      float_of_int acc.ma_compaction_saved_tokens /. float_of_int acc.ma_compaction_events
  in
  let memory_compaction_drop_ratio =
    if acc.ma_memory_compaction_before_notes = 0
    then 0.0
    else
      float_of_int acc.ma_memory_compaction_dropped_notes
      /. float_of_int acc.ma_memory_compaction_before_notes
  in
  let memory_compaction_drop_avg =
    if acc.ma_memory_compaction_events = 0
    then 0.0
    else
      float_of_int acc.ma_memory_compaction_dropped_notes
      /. float_of_int acc.ma_memory_compaction_events
  in
  let memory_failed = acc.ma_memory_checks - acc.ma_memory_passed in
  let memory_pass_rate =
    if acc.ma_memory_checks = 0
    then 0.0
    else float_of_int acc.ma_memory_passed /. float_of_int acc.ma_memory_checks
  in
  let memory_avg_score =
    if acc.ma_memory_checks = 0
    then 0.0
    else acc.ma_memory_score_sum /. float_of_int acc.ma_memory_checks
  in
  let memory_weather_pass_rate =
    if acc.ma_memory_weather_checks = 0
    then 0.0
    else
      float_of_int acc.ma_memory_weather_passed
      /. float_of_int acc.ma_memory_weather_checks
  in
  let repetition_risk_avg =
    if acc.ma_repetition_risk_points = 0
    then 0.0
    else acc.ma_repetition_risk_sum /. float_of_int acc.ma_repetition_risk_points
  in
  let goal_alignment_avg =
    if acc.ma_goal_alignment_points = 0
    then 0.0
    else acc.ma_goal_alignment_sum /. float_of_int acc.ma_goal_alignment_points
  in
  let response_alignment_avg =
    if acc.ma_response_alignment_points = 0
    then 0.0
    else acc.ma_response_alignment_sum /. float_of_int acc.ma_response_alignment_points
  in
  let goal_drift_avg =
    if acc.ma_goal_drift_points = 0
    then 0.0
    else acc.ma_goal_drift_sum /. float_of_int acc.ma_goal_drift_points
  in
  let top_work_kinds = top_counts_json ~limit:5 ~name_key:"kind" work_kind_counts in
  let top_models = top_counts_json ~limit:5 ~name_key:"model" model_counts_window in
  let top_tools = top_counts_json ~limit:5 ~name_key:"tool" tool_counts_window in
  let top_memory_kinds =
    top_counts_json ~limit:5 ~name_key:"kind" memory_kind_counts_window
  in
  let top_drift_reasons =
    top_counts_json ~limit:5 ~name_key:"reason" drift_reason_counts
  in
  let top_compaction_triggers =
    top_counts_json ~limit:5 ~name_key:"reason" compaction_trigger_counts
  in
  let generation_equipment =
    generation_stats
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.sort (fun (ga, _) (gb, _) -> compare ga gb)
    |> List.map (fun (generation, gs) ->
      let memory_pass_rate_gen =
        if gs.memory_checks = 0
        then 0.0
        else float_of_int gs.memory_passed /. float_of_int gs.memory_checks
      in
      let top_model =
        match top_count_name_and_count gs.models with
        | Some (name, count) -> `Assoc [ "name", `String name; "count", `Int count ]
        | None -> `Null
      in
      let top_tool =
        match top_count_name_and_count gs.tools with
        | Some (name, count) -> `Assoc [ "name", `String name; "count", `Int count ]
        | None -> `Null
      in
      `Assoc
        [ "generation", `Int generation
        ; "turns", `Int gs.turns
        ; "input_tokens", `Int gs.input_tokens
        ; "output_tokens", `Int gs.output_tokens
        ; "total_tokens", `Int gs.total_tokens
        ; "handoffs", `Int gs.handoffs
        ; "compactions", `Int gs.compactions
        ; "memory_compactions", `Int gs.memory_compactions
        ; "memory_trimmed", `Int gs.memory_trimmed
        ; "memory_checks", `Int gs.memory_checks
        ; "memory_pass_rate", `Float memory_pass_rate_gen
        ; "memory_notes", `Int gs.memory_notes
        ; "first_ts_unix", `Float gs.first_ts
        ; "last_ts_unix", `Float gs.last_ts
        ; "top_model", top_model
        ; "top_tool", top_tool
        ])
  in
  let summary =
    `Assoc
      [ "sample_points", `Int sample_points
      ; "window_sample_points", `Int sample_points
      ; "turn_points", `Int turn_points_int
      ; "window_turn_points", `Int turn_points_int
      ; "heartbeat_points", `Int acc.ma_heartbeat_points
      ; "window_heartbeat_points", `Int acc.ma_heartbeat_points
      ; "proactive_points", `Int proactive_points_int
      ; "window_proactive_points", `Int proactive_points_int
      ; "window_interactions", `Int interaction_points_int
      ; "window_turns", `Int turn_points_int
      ; "window_series_max_lines", `Int series_points
      ; "window_series_max_bytes", `Int metrics_window_max_bytes
      ; "primary_model", `String primary_model
      ; "handoff_count", `Int acc.ma_handoff_count
      ; "compaction_events", `Int acc.ma_compaction_events
      ; "compaction_before_tokens", `Int acc.ma_compaction_before_tokens
      ; "compaction_saved_tokens", `Int acc.ma_compaction_saved_tokens
      ; "compaction_saved_ratio", `Float compaction_saved_ratio
      ; "avg_compaction_saved_tokens", `Float avg_compaction_saved_tokens
      ; "fallback_count", `Int acc.ma_fallback_count
      ; "fallback_rate", `Float fallback_rate
      ; "model_fallback_count", `Int acc.ma_fallback_count
      ; "model_fallback_rate", `Float fallback_rate
      ; "model_fallback_numerator", `Int acc.ma_fallback_count
      ; "model_fallback_denominator", `Int interaction_points_int
      ; "proactive_fallback_count", `Int acc.ma_proactive_fallback_count
      ; "proactive_fallback_rate", `Float proactive_fallback_rate
      ; "proactive_template_fallback_count", `Int acc.ma_proactive_fallback_count
      ; "proactive_template_fallback_rate", `Float proactive_fallback_rate
      ; "proactive_template_fallback_numerator", `Int acc.ma_proactive_fallback_count
      ; "proactive_template_fallback_denominator", `Int proactive_points_int
      ; "intervention_share", `Float intervention_share
      ; "intervention_per_turn", `Float intervention_per_turn
      ; "auto_reflect_count", `Int acc.ma_auto_reflect_count
      ; "auto_plan_count", `Int acc.ma_auto_plan_count
      ; "auto_compact_count", `Int acc.ma_auto_compact_count
      ; "auto_handoff_count", `Int acc.ma_auto_handoff_count
      ; "guardrail_stop_count", `Int acc.ma_guardrail_stop_count
      ; "auto_reflect_rate", `Float auto_reflect_rate
      ; "auto_plan_rate", `Float auto_plan_rate
      ; "auto_compact_rate", `Float auto_compact_rate
      ; "auto_handoff_rate", `Float auto_handoff_rate
      ; "guardrail_stop_rate", `Float guardrail_stop_rate
      ; "drift_applied_count", `Int acc.ma_drift_applied_count
      ; "drift_applied_rate", `Float drift_applied_rate
      ; "repetition_risk_avg", `Float repetition_risk_avg
      ; "goal_alignment_avg", `Float goal_alignment_avg
      ; "response_alignment_avg", `Float response_alignment_avg
      ; "goal_drift_avg", `Float goal_drift_avg
      ; "proactive_preview_sample_count", `Int proactive_preview_sample_count
      ; "proactive_preview_pair_count", `Int proactive_preview_pair_count
      ; "proactive_preview_similarity_avg", `Float proactive_preview_similarity_avg
      ; "proactive_preview_similarity_max", `Float proactive_preview_similarity_max
      ; "proactive_preview_similarity_warn", `Bool proactive_preview_similarity_warn
      ; "proactive_preview_similarity_method", `String "jaccard_adjacent_preview"
      ; "proactive_preview_similarity_window", `Int proactive_similarity_window
      ; "tool_call_count", `Int acc.ma_tool_call_count
      ; "memory_checks", `Int acc.ma_memory_checks
      ; "memory_passed", `Int acc.ma_memory_passed
      ; "memory_failed", `Int memory_failed
      ; "memory_pass_rate", `Float memory_pass_rate
      ; "memory_avg_score", `Float memory_avg_score
      ; "memory_threshold", `Float acc.ma_memory_threshold
      ; "memory_corrections", `Int acc.ma_memory_corrections
      ; "memory_correction_success", `Int acc.ma_memory_correction_success
      ; "memory_notes_added", `Int acc.ma_memory_notes_added
      ; "memory_compaction_events", `Int acc.ma_memory_compaction_events
      ; "memory_compaction_before_notes", `Int acc.ma_memory_compaction_before_notes
      ; "memory_compaction_dropped_notes", `Int acc.ma_memory_compaction_dropped_notes
      ; "memory_compaction_invalid_dropped", `Int acc.ma_memory_compaction_invalid_dropped
      ; "memory_compaction_drop_ratio", `Float memory_compaction_drop_ratio
      ; "memory_compaction_drop_avg", `Float memory_compaction_drop_avg
      ; "memory_weather_checks", `Int acc.ma_memory_weather_checks
      ; "memory_weather_passed", `Int acc.ma_memory_weather_passed
      ; "memory_weather_pass_rate", `Float memory_weather_pass_rate
      ; "top_work_kinds", `List top_work_kinds
      ; "top_models", `List top_models
      ; "top_tools", `List top_tools
      ; "top_memory_kinds", `List top_memory_kinds
      ; "top_drift_reasons", `List top_drift_reasons
      ; "top_compaction_triggers", `List top_compaction_triggers
      ; "generation_equipment", `List generation_equipment
      ]
  in
  items, summary, acc.ma_last_handoff, acc.ma_last_compaction
;;
