(** Runtime-lens proof aggregation for keeper runtime trace responses.

    Split from {!Server_dashboard_http_keeper_api}; this module keeps the
    tool-call proof scanner independent from HTTP handler assembly. *)

open Server_dashboard_http_keeper_api_types

type runtime_lens_proof_acc =
  { mutable matched_tool_call_count : int
  ; mutable successful_tool_call_count : int
  ; mutable failed_tool_call_count : int
  ; mutable latest_ts : float option
  ; tools : (string, unit) Hashtbl.t
  ; successful_tools : (string, unit) Hashtbl.t
  ; failed_tools : (string, unit) Hashtbl.t
  }

let runtime_lens_proof_acc () =
  { matched_tool_call_count = 0
  ; successful_tool_call_count = 0
  ; failed_tool_call_count = 0
  ; latest_ts = None
  ; tools = Hashtbl.create 8
  ; successful_tools = Hashtbl.create 8
  ; failed_tools = Hashtbl.create 8
  }

let runtime_lens_set_add table value =
  let value = String.trim value in
  if value <> "" then Hashtbl.replace table value ()

let runtime_lens_sorted_set table =
  Hashtbl.fold (fun value () acc -> value :: acc) table []
  |> List.sort_uniq String.compare

let runtime_lens_update_latest_ts acc json =
  let ts_opt =
    match Json_util.assoc_member_opt "ts" json with
    | Some (`Float value) -> Some value
    | Some (`Int value) -> Some (Float.of_int value)
    | _ -> None
  in
  match ts_opt with
  | Some ts ->
      acc.latest_ts <-
        (match acc.latest_ts with
         | Some previous when previous >= ts -> acc.latest_ts
         | _ -> Some ts)
  | None -> ()

let runtime_lens_accumulate_tool_proof acc json =
  acc.matched_tool_call_count <- acc.matched_tool_call_count + 1;
  runtime_lens_update_latest_ts acc json;
  let tool = Option.value (Json_util.get_string json "tool") ~default:"unknown_tool" in
  runtime_lens_set_add acc.tools tool;
  if Json_util.get_bool json "success" = Some true then (
    acc.successful_tool_call_count <- acc.successful_tool_call_count + 1;
    runtime_lens_set_add acc.successful_tools tool)
  else (
    acc.failed_tool_call_count <- acc.failed_tool_call_count + 1;
    runtime_lens_set_add acc.failed_tools tool)

let runtime_lens_runtime_proof_json ~keeper_name ~trace_id ?turn_id () =
  let acc = runtime_lens_proof_acc () in
  Keeper_tool_call_log.read_recent ~keeper_name ~n:200 ()
  |> List.iter (fun json ->
       if tool_call_matches_trace ?turn_id ~keeper_name ~trace_id json
       then runtime_lens_accumulate_tool_proof acc json);
  let status =
    if acc.successful_tool_call_count > 0 then "pass"
    else if acc.matched_tool_call_count > 0 then "warn"
    else "missing"
  in
  `Assoc
    [ ("source", `String "keeper_tool_call_log")
    ; ("status", `String status)
    ; ("matched_tool_call_count", `Int acc.matched_tool_call_count)
    ; ("successful_tool_call_count", `Int acc.successful_tool_call_count)
    ; ("failed_tool_call_count", `Int acc.failed_tool_call_count)
    ; ("tools", Json_util.json_string_list (runtime_lens_sorted_set acc.tools))
    ; ( "successful_tools",
        Json_util.json_string_list (runtime_lens_sorted_set acc.successful_tools) )
    ; ("failed_tools", Json_util.json_string_list (runtime_lens_sorted_set acc.failed_tools))
    ; ( "latest_at",
        match acc.latest_ts with
        | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
        | None -> `Null )
    ]
