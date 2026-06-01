(** Runtime-lens proof aggregation for keeper runtime trace responses.

    Split from {!Server_dashboard_http_keeper_api}; this module keeps the
    tool-call proof scanner independent from HTTP handler assembly. *)

open Server_dashboard_http_keeper_api_types

type runtime_lens_proof_acc =
  { mutable matched_tool_call_count : int
  ; mutable successful_tool_call_count : int
  ; mutable failed_tool_call_count : int
  ; mutable latest_ts : float option
  ; mutable docker_visible : bool
  ; tools : (string, unit) Hashtbl.t
  ; successful_tools : (string, unit) Hashtbl.t
  ; failed_tools : (string, unit) Hashtbl.t
  ; sandbox_profiles : (string, unit) Hashtbl.t
  ; network_modes : (string, unit) Hashtbl.t
  }

let runtime_lens_proof_acc () =
  { matched_tool_call_count = 0
  ; successful_tool_call_count = 0
  ; failed_tool_call_count = 0
  ; latest_ts = None
  ; docker_visible = false
  ; tools = Hashtbl.create 8
  ; successful_tools = Hashtbl.create 8
  ; failed_tools = Hashtbl.create 8
  ; sandbox_profiles = Hashtbl.create 4
  ; network_modes = Hashtbl.create 4
  }

let string_contains = String_util.string_contains_substring_ci

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

let rec runtime_lens_json_string_values field = function
  | `Assoc fields ->
      let direct =
        match List.assoc_opt field fields with
        | Some (`String value) -> [ value ]
        | _ -> []
      in
      direct
      @ List.concat_map
          (fun (_, value) -> runtime_lens_json_string_values field value)
          fields
  | `List values -> List.concat_map (runtime_lens_json_string_values field) values
  | _ -> []

let runtime_lens_has_string_field json field expected =
  runtime_lens_json_string_values field json
  |> List.exists (String.equal expected)

let runtime_lens_tool_text json =
  let input = (match Json_util.assoc_member_opt "input" json with Some v -> v | None -> `Null) |> Yojson.Safe.to_string in
  let output = Option.value (tool_call_output_text_opt json) ~default:"" in
  input ^ "\n" ^ output

let runtime_lens_text_contains text needle =
  string_contains ~needle text

let runtime_lens_call_has_docker_proof json output_opt text =
  Json_util.get_string json "sandbox_profile" = Some "docker"
  || Json_util.get_string (tool_call_runtime_contract json) "sandbox_profile"
     = Some "docker"
  || runtime_lens_text_contains text "\"sandbox_profile\":\"docker\""
  || runtime_lens_text_contains text "\"via\":\"docker\""
  ||
  match output_opt with
  | Some output ->
      runtime_lens_has_string_field output "sandbox_profile" "docker"
      || runtime_lens_has_string_field output "via" "docker"
  | None -> false

let runtime_lens_collect_profile acc json =
  let add_from table field source =
    match Json_util.get_string source field with
    | Some value -> runtime_lens_set_add table value
    | None -> ()
  in
  add_from acc.sandbox_profiles "sandbox_profile" json;
  add_from acc.sandbox_profiles "sandbox_profile" (tool_call_runtime_contract json);
  add_from acc.network_modes "network_mode" json;
  add_from acc.network_modes "network_mode" (tool_call_runtime_contract json)

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
    runtime_lens_set_add acc.failed_tools tool);
  runtime_lens_collect_profile acc json;
  let output_opt = parse_tool_output_json_opt json in
  let text = runtime_lens_tool_text json in
  if runtime_lens_call_has_docker_proof json output_opt text
  then acc.docker_visible <- true

let runtime_lens_runtime_proof_json ~keeper_name ~trace_id ?turn_id () =
  let acc = runtime_lens_proof_acc () in
  Keeper_tool_call_log.read_recent ~keeper_name ~n:200 ()
  |> List.iter (fun json ->
       if tool_call_matches_trace ?turn_id ~keeper_name ~trace_id json
       then runtime_lens_accumulate_tool_proof acc json);
  let status =
    if acc.docker_visible then "pass"
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
    ; ( "sandbox_profiles",
        Json_util.json_string_list (runtime_lens_sorted_set acc.sandbox_profiles) )
    ; ("network_modes", Json_util.json_string_list (runtime_lens_sorted_set acc.network_modes))
    ; ("docker_visible", `Bool acc.docker_visible)
    ; ( "latest_at",
        match acc.latest_ts with
        | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
        | None -> `Null )
    ]
