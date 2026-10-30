(** Dashboard_http_keeper_detail — current keeper metrics projection.

    Only rows carrying [Keeper_metrics_record]'s current discriminator are
    decoded. The versionless metrics ledger contract is retired. *)

include Dashboard_http_keeper_metrics

type metrics_acc =
  { ma_sample_points : int
  ; ma_tool_call_count : int
  ; ma_turn_points : int
  ; ma_heartbeat_points : int
  ; ma_proactive_points : int
  }

let init_acc =
  { ma_sample_points = 0
  ; ma_tool_call_count = 0
  ; ma_turn_points = 0
  ; ma_heartbeat_points = 0
  ; ma_proactive_points = 0
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
  : Yojson.Safe.t list * Yojson.Safe.t =
  let member key source =
    match Json_util.assoc_member_opt key source with
    | Some value -> value
    | None -> `Null
  in
  let work_kind_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let tool_counts_window : (string, int) Hashtbl.t = Hashtbl.create 16 in
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
               Safe_ops.json_int_opt "latency_ms" json,
               Safe_ops.json_int_opt "tool_call_count" json,
               string_list_member_opt "tools_used" json,
               Keeper_unified_metrics.work_kind_of_json json,
               parsed_channel
             with
             | ( Some ts_unix
               , Some trace_id
               , Some latency_ms
               , Some tool_call_count
               , Some tools_used
               , Some work_kind
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
                 let usage_obj = member "usage" json in
                 let runtime_obj = member "runtime" json in
                 let acc =
                   { acc with
                     ma_sample_points = acc.ma_sample_points + 1
                   ; ma_turn_points =
                       acc.ma_turn_points + if is_turn then 1 else 0
                   ; ma_proactive_points =
                       acc.ma_proactive_points
                       + if is_scheduled_autonomous then 1 else 0
                   ; ma_tool_call_count =
                       acc.ma_tool_call_count + tool_call_count
                   }
                 in
                 count_table_incr work_kind_counts work_kind;
                 List.iter (count_table_incr tool_counts_window) tools_used;
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
      ; ( "intervention_share"
        , Json_util.int_ratio_json acc.ma_proactive_points interaction_points )
      ; ( "intervention_per_turn"
        , Json_util.int_ratio_json acc.ma_proactive_points acc.ma_turn_points )
      ; "tool_call_count", `Int acc.ma_tool_call_count
      ; "top_work_kinds", `List top_work_kinds
      ; "top_tools", `List top_tools
      ]
  in
  items, summary
