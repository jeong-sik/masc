open Dashboard_http_keeper_types

let recent_keeper_metric_jsons (config : Coord.config) name =
  let metrics_store = Keeper_types.keeper_metrics_store config name in
  let lines =
    let dated = Dated_jsonl.read_recent_lines metrics_store 80 in
    if dated <> []
    then dated
    else (
      let metrics_path = Keeper_types.keeper_metrics_path config name in
      Keeper_memory.read_file_tail_lines metrics_path ~max_bytes:120000 ~max_lines:80)
  in
  List.filter_map parse_json_line_opt lines
;;

let recent_token_spend_json metrics =
  metrics
  |> List.filter_map (fun json ->
    let input_tokens = int_member_fallback "input_tokens" json in
    let output_tokens = int_member_fallback "output_tokens" json in
    let total_tokens =
      match int_member_fallback "total_tokens" json with
      | Some value -> Some value
      | None ->
        (match input_tokens, output_tokens with
         | Some input, Some output -> Some (input + output)
         | _ -> None)
    in
    match input_tokens, output_tokens, total_tokens with
    | None, None, None -> None
    | _ ->
      Some
        (`Assoc
           [ "ts_unix", `Float (metric_ts json)
           ; "ts", Json_util.string_opt_to_json (string_member_nonempty "ts" json)
           ; ( "channel"
             , Json_util.string_opt_to_json (string_member_nonempty "channel" json) )
           ; "model", `Null
           ; "input_tokens", Json_util.int_opt_to_json input_tokens
           ; "output_tokens", Json_util.int_opt_to_json output_tokens
           ; "total_tokens", Json_util.int_opt_to_json total_tokens
           ]))
  |> sort_by_latest_ts
  |> take_list 5
;;

let latest_tool_call_json name =
  Keeper_tool_call_log.read_recent ~keeper_name:name ~n:10 ()
  |> List.sort (fun left right ->
    Float.compare
      (Safe_ops.json_float ~default:0.0 "ts" right)
      (Safe_ops.json_float ~default:0.0 "ts" left))
  |> List.find_opt (fun json ->
    match string_member_nonempty "tool" json with
    | Some _ -> true
    | None -> false)
  |> Option.map (fun json ->
    `Assoc
      [ "ts_unix", Json_util.float_opt_to_json (Safe_ops.json_float_opt "ts" json)
      ; "tool", Json_util.string_opt_to_json (string_member_nonempty "tool" json)
      ; "success", Json_util.bool_opt_to_json (Safe_ops.json_bool_opt "success" json)
      ; ( "semantic_outcome"
        , Json_util.string_opt_to_json (string_member_nonempty "semantic_outcome" json) )
      ; "duration_ms", Json_util.float_opt_to_json (Safe_ops.json_float_opt "duration_ms" json)
      ])
;;

let keeper_bdi_snapshot_json (config : Coord.config) (name : string)
    : [ `OK | `Not_found ] * Yojson.Safe.t
  =
  match Keeper_types.read_meta config name with
  | Error msg -> `Not_found, `Assoc [ "error", `String msg ]
  | Ok None ->
    ( `Not_found
    , `Assoc [ "error", `String (Printf.sprintf "keeper %S not found" name) ] )
  | Ok (Some (m : Keeper_types.keeper_meta)) ->
    let metrics = recent_keeper_metric_jsons config name in
    let latest_social =
      sort_by_latest_ts metrics
      |> List.find_opt (fun json ->
        Option.is_some (string_member_nonempty "belief_summary" json)
        || Option.is_some (string_member_nonempty "active_desire" json)
        || Option.is_some (string_member_nonempty "current_intention" json)
        || Option.is_some (string_member_nonempty "need" json))
    in
    let metric_field key = Option.bind latest_social (string_member_nonempty key) in
    let belief =
      match metric_field "belief_summary" with
      | Some value -> Some value
      | None ->
        (match m.runtime.last_blocker with
         | Some info ->
           let trimmed = String.trim info.detail in
           let label =
             if trimmed = ""
             then Keeper_types.blocker_class_to_string info.klass
             else trimmed
           in
           Some ("blocked: " ^ label)
         | None -> None)
    in
    let desire =
      match metric_field "active_desire" with
      | Some value -> Some value
      | None -> nonempty_string_opt m.runtime.last_active_desire
    in
    let intention =
      match metric_field "current_intention" with
      | Some value -> Some value
      | None -> nonempty_string_opt m.runtime.last_current_intention
    in
    let need =
      match metric_field "need" with
      | Some value -> Some value
      | None -> nonempty_string_opt m.runtime.last_need
    in
    ( `OK
    , `Assoc
        [ "keeper", `String m.name
        ; "generated_at", `String (Masc_domain.now_iso ())
        ; "poll_interval_ms", `Int 5000
        ; "belief", Json_util.string_opt_to_json belief
        ; "desire", Json_util.string_opt_to_json desire
        ; "intention", Json_util.string_opt_to_json intention
        ; "need", Json_util.string_opt_to_json need
        ; "profile_will", Json_util.string_opt_to_json (nonempty_string_opt m.will)
        ; "profile_needs", Json_util.string_opt_to_json (nonempty_string_opt m.needs)
        ; "profile_desires", Json_util.string_opt_to_json (nonempty_string_opt m.desires)
        ; "recent_token_spend", `List (recent_token_spend_json metrics)
        ; "last_tool_call", Json_util.option_to_yojson (fun x -> x) (latest_tool_call_json name)
        ; "source", `String "keeper_meta+metrics_jsonl+tool_call_log"
        ] )
;;
