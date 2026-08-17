(** Dashboard_http_keeper_detail — current keeper metrics projection.

    Only rows carrying [Keeper_metrics_record]'s current discriminator are
    decoded. The versionless metrics ledger contract is retired. *)

include Dashboard_http_keeper_metrics

type metrics_acc =
  { ma_sample_points : int
  ; ma_handoff_count : int
  ; ma_tool_call_count : int
  ; ma_turn_points : int
  ; ma_heartbeat_points : int
  ; ma_proactive_points : int
  ; ma_last_handoff : Yojson.Safe.t option
  }

let init_acc =
  { ma_sample_points = 0
  ; ma_handoff_count = 0
  ; ma_tool_call_count = 0
  ; ma_turn_points = 0
  ; ma_heartbeat_points = 0
  ; ma_proactive_points = 0
  ; ma_last_handoff = None
  }

let string_list_member_opt key json =
  match Json_util.assoc_member_opt key json with
  | Some (`List values) ->
      let rec decode acc = function
        | [] -> Some (List.rev acc)
        | `String value :: rest ->
            let value = String.trim value in
            if value = "" then None else decode (value :: acc) rest
        | _ -> None
      in
      decode [] values
  | _ -> None

let compute_metrics_window
    ~(parsed_metrics : Yojson.Safe.t list)
    ~(compact : bool)
    ~(series_points : int)
  : Yojson.Safe.t list * Yojson.Safe.t * Yojson.Safe.t option =
  let member key source =
    match Json_util.assoc_member_opt key source with
    | Some value -> value
    | None -> `Null
  in
  let work_kind_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let tool_counts_window : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let generation_stats : (int, keeper_gen_window_stats) Hashtbl.t =
    Hashtbl.create 8
  in
  let acc, items_rev =
    List.fold_left
      (fun (acc, items) json ->
        match Keeper_metrics_record.kind_of_json json with
        | None -> acc, items
        | Some Keeper_metrics_record.Heartbeat ->
            (match
               Safe_ops.json_float_opt "ts_unix" json,
               Safe_ops.json_string_opt "channel" json
             with
             | Some _, Some "heartbeat" ->
                 ( { acc with
                     ma_sample_points = acc.ma_sample_points + 1
                   ; ma_heartbeat_points = acc.ma_heartbeat_points + 1
                   }
                 , items )
             | _ -> acc, items)
        | Some Keeper_metrics_record.Turn ->
            let parsed_channel =
              Option.bind
                (Safe_ops.json_string_opt "channel" json)
                Keeper_world_observation.channel_of_string
            in
            (match
               Safe_ops.json_float_opt "ts_unix" json,
               Safe_ops.json_string_nonempty_opt "trace_id" json,
               Safe_ops.json_int_opt "generation" json,
               Safe_ops.json_int_opt "latency_ms" json,
               Safe_ops.json_int_opt "tool_call_count" json,
               string_list_member_opt "tools_used" json,
               Keeper_unified_metrics.work_kind_of_json json,
               Safe_ops.json_bool_opt "handoff_performed" json,
               parsed_channel
             with
             | ( Some ts_unix
               , Some trace_id
               , Some generation
               , Some latency_ms
               , Some tool_call_count
               , Some tools_used
               , Some work_kind
               , Some handoff_performed
               , Some channel ) ->
                 let is_turn =
                   match channel with
                   | Keeper_world_observation.Reactive -> true
                   | Keeper_world_observation.Scheduled_autonomous -> false
                 in
                 let is_scheduled_autonomous =
                   Keeper_world_observation.is_autonomous channel
                 in
                 let channel_wire =
                   Keeper_world_observation.channel_to_string channel
                 in
                 let handoff_obj = member "handoff" json in
                 let handoff_prev_trace_id =
                   Safe_ops.json_string_nonempty_opt "prev_trace_id" handoff_obj
                 in
                 let handoff_new_trace_id =
                   Safe_ops.json_string_nonempty_opt "new_trace_id" handoff_obj
                 in
                 let handoff_new_generation =
                   Safe_ops.json_int_opt "to_generation" handoff_obj
                 in
                 let usage_obj = member "usage" json in
                 let input_tokens =
                   Safe_ops.json_int_opt "input_tokens" usage_obj
                 in
                 let output_tokens =
                   Safe_ops.json_int_opt "output_tokens" usage_obj
                 in
                 let total_tokens =
                   Safe_ops.json_int_opt "total_tokens" usage_obj
                 in
                 let usage =
                   match input_tokens, output_tokens, total_tokens with
                   | Some input, Some output, Some total ->
                       Some (input, output, total)
                   | _ -> None
                 in
                 let runtime_obj = member "runtime" json in
                 let acc =
                   { acc with
                     ma_sample_points = acc.ma_sample_points + 1
                   ; ma_turn_points =
                       acc.ma_turn_points + if is_turn then 1 else 0
                   ; ma_proactive_points =
                       acc.ma_proactive_points
                       + if is_scheduled_autonomous then 1 else 0
                   ; ma_handoff_count =
                       acc.ma_handoff_count
                       + if handoff_performed then 1 else 0
                   ; ma_tool_call_count =
                       acc.ma_tool_call_count + tool_call_count
                   ; ma_last_handoff =
                       if handoff_performed
                       then
                         Some
                           (`Assoc
                             [ "ts_unix", `Float ts_unix
                             ; "trace_id", `String trace_id
                             ; "generation", `Int generation
                             ; ( "prev_trace_id"
                               , Json_util.string_opt_to_json
                                   handoff_prev_trace_id )
                             ; ( "new_trace_id"
                               , Json_util.string_opt_to_json
                                   handoff_new_trace_id )
                             ; ( "to_generation"
                               , Json_util.int_opt_to_json
                                   handoff_new_generation )
                             ])
                       else acc.ma_last_handoff
                   }
                 in
                 count_table_incr work_kind_counts work_kind;
                 List.iter (count_table_incr tool_counts_window) tools_used;
                 let generation_stats_row =
                   match Hashtbl.find_opt generation_stats generation with
                   | Some stats -> stats
                   | None -> create_keeper_gen_window_stats ()
                 in
                 let usage_points, input_tokens, output_tokens, total_tokens =
                   match usage with
                   | Some (input, output, total) ->
                       ( generation_stats_row.usage_points + 1,
                         generation_stats_row.input_tokens + input,
                         generation_stats_row.output_tokens + output,
                         generation_stats_row.total_tokens + total )
                   | None ->
                       ( generation_stats_row.usage_points,
                         generation_stats_row.input_tokens,
                         generation_stats_row.output_tokens,
                         generation_stats_row.total_tokens )
                 in
                 (* [Hashtbl.replace] inserts when the generation is new, so
                    the row no longer has to be added before it is filled in.
                    [tools] is the same table either way — the record update
                    copies the handle, not the contents. *)
                 Hashtbl.replace generation_stats generation
                   {
                     generation_stats_row with
                     turns = generation_stats_row.turns + 1;
                     usage_points;
                     input_tokens;
                     output_tokens;
                     total_tokens;
                     handoffs =
                       (if handoff_performed
                        then generation_stats_row.handoffs + 1
                        else generation_stats_row.handoffs);
                     first_ts =
                       (if
                          generation_stats_row.first_ts <= 0.0
                          || ts_unix < generation_stats_row.first_ts
                        then ts_unix
                        else generation_stats_row.first_ts);
                     last_ts =
                       (if ts_unix > generation_stats_row.last_ts
                        then ts_unix
                        else generation_stats_row.last_ts);
                   };
                 List.iter
                   (count_table_incr generation_stats_row.tools)
                   tools_used;
                 let output_item =
                   if compact
                   then None
                   else
                     Some
                       (`Assoc
                         [ "ts_unix", `Float ts_unix
                         ; "trace_id", `String trace_id
                         ; "channel", `String channel_wire
                         ; "context_ratio", `Null
                         ; "context_tokens", `Null
                         ; "context_max", `Null
                         ; ( "message_count"
                           , Json_util.int_opt_to_json
                               (Safe_ops.json_int_opt "message_count" json) )
                         ; "handoff_performed", `Bool handoff_performed
                         ; ( "handoff"
                           , if handoff_performed
                             then
                               `Assoc
                                 [ "performed", `Bool true
                                 ; ( "prev_trace_id"
                                   , Json_util.string_opt_to_json
                                       handoff_prev_trace_id )
                                 ; ( "new_trace_id"
                                   , Json_util.string_opt_to_json
                                       handoff_new_trace_id )
                                 ; ( "to_generation"
                                   , Json_util.int_opt_to_json
                                       handoff_new_generation )
                                 ]
                             else `Null )
                         ; "generation", `Int generation
                         ; "usage", usage_obj
                         ; "latency_ms", `Int latency_ms
                         ; ( "cost_usd"
                           , Json_util.float_opt_to_json
                               (Safe_ops.json_float_opt "cost_usd" json) )
                         ; "prompt_fingerprint", member "prompt_fingerprint" json
                         ; "prompt", member "prompt" json
                         ; "ctx_composition", member "ctx_composition" json
                         ; "runtime", runtime_obj
                         ; "work_kind", `String work_kind
                         ; "tool_call_count", `Int tool_call_count
                         ; ( "tools_used"
                           , `List
                               (List.map
                                  (fun tool -> `String tool)
                                  tools_used) )
                         ; ( "inference_telemetry"
                           , json
                             |> member "inference_telemetry"
                             |> Keeper_hooks_agent_core
                                  .redact_inference_telemetry_json )
                         ])
                 in
                 (match output_item with
                  | Some item -> acc, item :: items
                  | None -> acc, items)
             | _ -> acc, items))
      (init_acc, [])
      parsed_metrics
  in
  let items = List.rev items_rev in
  let interaction_points = acc.ma_turn_points + acc.ma_proactive_points in
  let top_work_kinds =
    top_counts_json ~limit:5 ~name_key:"kind" work_kind_counts
  in
  let top_tools =
    top_counts_json ~limit:5 ~name_key:"tool" tool_counts_window
  in
  let generation_equipment =
    generation_stats
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.sort (fun (left, _) (right, _) -> compare left right)
    |> List.map (fun (generation, stats) ->
         let top_tool =
           match top_count_name_and_count stats.tools with
           | Some (name, count) ->
               `Assoc [ "name", `String name; "count", `Int count ]
           | None -> `Null
         in
         let usage_json value =
           if stats.usage_points = 0 then `Null else `Int value
         in
         `Assoc
           [ "generation", `Int generation
           ; "turns", `Int stats.turns
           ; "usage_points", `Int stats.usage_points
           ; "input_tokens", usage_json stats.input_tokens
           ; "output_tokens", usage_json stats.output_tokens
           ; "total_tokens", usage_json stats.total_tokens
           ; "handoffs", `Int stats.handoffs
           ; "first_ts_unix", `Float stats.first_ts
           ; "last_ts_unix", `Float stats.last_ts
           ; "top_tool", top_tool
           ])
  in
  let summary =
    `Assoc
      [ "sample_points", `Int acc.ma_sample_points
      ; "window_sample_points", `Int acc.ma_sample_points
      ; "turn_points", `Int acc.ma_turn_points
      ; "window_turn_points", `Int acc.ma_turn_points
      ; "heartbeat_points", `Int acc.ma_heartbeat_points
      ; "window_heartbeat_points", `Int acc.ma_heartbeat_points
      ; "proactive_points", `Int acc.ma_proactive_points
      ; "window_proactive_points", `Int acc.ma_proactive_points
      ; "window_interactions", `Int interaction_points
      ; "window_turns", `Int acc.ma_turn_points
      ; "window_series_max_lines", `Int series_points
      ; "handoff_count", `Int acc.ma_handoff_count
      ; ( "intervention_share"
        , Json_util.int_ratio_json acc.ma_proactive_points interaction_points )
      ; ( "intervention_per_turn"
        , Json_util.int_ratio_json acc.ma_proactive_points acc.ma_turn_points )
      ; "tool_call_count", `Int acc.ma_tool_call_count
      ; "top_work_kinds", `List top_work_kinds
      ; "top_tools", `List top_tools
      ; "generation_equipment", `List generation_equipment
      ]
  in
  items, summary, acc.ma_last_handoff
