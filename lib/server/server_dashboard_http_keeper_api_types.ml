(** Server_dashboard_http_keeper_api_types — pure routing types + helpers
    extracted from Server_dashboard_http_keeper_api (3136 LoC godfile).

    See server_dashboard_http_keeper_api_types.mli for rationale. *)

let keeper_api_prefix = "/api/v1/keepers/"
let keeper_suffix_tools = "/tools"
let keeper_suffix_config = "/config"
let keeper_suffix_boot = "/boot"
let keeper_suffix_shutdown = "/shutdown"
let keeper_suffix_reset = "/reset"
let keeper_suffix_clear = "/clear"
let keeper_suffix_checkpoints = "/checkpoints"
let keeper_suffix_runtime_trace = "/runtime-trace"
let keeper_suffix_directive = "/directive"
let keeper_suffix_bdi_snapshot = "/bdi-snapshot"

type keeper_post_route_kind =
  | Keeper_post_tools
  | Keeper_post_config
  | Keeper_post_boot
  | Keeper_post_shutdown
  | Keeper_post_reset
  | Keeper_post_clear
  | Keeper_post_checkpoints
  | Keeper_post_directive
  | Keeper_post_unknown

let classify_keeper_post_route req_path =
  if not (String.starts_with ~prefix:keeper_api_prefix req_path) then
    Keeper_post_unknown
  else
    let plen = String.length keeper_api_prefix in
    let tlen = String.length req_path in
    let ends_with suffix =
      tlen > plen + String.length suffix
      && String.ends_with ~suffix req_path
    in
    if ends_with keeper_suffix_tools then Keeper_post_tools
    else if ends_with keeper_suffix_config then Keeper_post_config
    else if ends_with keeper_suffix_boot then Keeper_post_boot
    else if ends_with keeper_suffix_shutdown then Keeper_post_shutdown
    else if ends_with keeper_suffix_reset then Keeper_post_reset
    else if ends_with keeper_suffix_clear then Keeper_post_clear
    else if ends_with keeper_suffix_checkpoints then Keeper_post_checkpoints
    else if ends_with keeper_suffix_directive then Keeper_post_directive
    else Keeper_post_unknown

let keeper_path_ends_with req_path suffix =
  let plen = String.length keeper_api_prefix in
  let tlen = String.length req_path in
  let slen = String.length suffix in
  tlen > plen + slen
  && String.starts_with ~prefix:keeper_api_prefix req_path
  && String.ends_with ~suffix req_path

let extract_keeper_name_for_suffix req_path suffix =
  let plen = String.length keeper_api_prefix in
  let slen = String.length suffix in
  let raw =
    String.trim
      (String.sub req_path plen (String.length req_path - plen - slen))
  in
  let valid =
    String.length raw > 0
    && String.length raw <= 128
    && String.to_seq raw
       |> Seq.for_all (fun c ->
            (c >= 'a' && c <= 'z')
            || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9')
            || c = '_' || c = '-')
  in
  if valid then raw else ""

let is_keeper_checkpoints_get_path req_path =
  keeper_path_ends_with req_path keeper_suffix_checkpoints

let is_keeper_runtime_trace_get_path req_path =
  keeper_path_ends_with req_path keeper_suffix_runtime_trace

let trim_to_opt (value : string) =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let truncate_text ~max_chars text =
  let len = String.length text in
  if len <= max_chars then text
  else if max_chars <= 1 then String.sub text 0 (max 0 max_chars)
  else
    String_util.utf8_safe ~max_bytes:max_chars ~suffix:"…" text
    |> String_util.to_string

let latest_preview_of_messages (messages : Agent_sdk.Types.message list) =
  messages
  |> List.rev
  |> List.find_map (fun (message : Agent_sdk.Types.message) ->
       if message.role = Agent_sdk.Types.System then None
       else
         Agent_sdk.Types.text_of_message message
         |> trim_to_opt
         |> Option.map (truncate_text ~max_chars:180))

let continuity_summary_of_messages (messages : Agent_sdk.Types.message list) =
  match Keeper_memory_policy.latest_state_snapshot_from_messages messages with
  | Some snapshot ->
      Keeper_memory_policy.keeper_state_snapshot_to_summary_text snapshot
      |> trim_to_opt
  | None -> None

let is_valid_keeper_name name =
  String.length name > 0
  && String.length name <= 128
  && String.to_seq name
     |> Seq.for_all (fun c ->
          (c >= 'a' && c <= 'z')
          || (c >= 'A' && c <= 'Z')
          || (c >= '0' && c <= '9')
          || c = '_' || c = '-')

let extract_keeper_name_for_post req_path suffix =
  let plen = String.length keeper_api_prefix in
  let slen = String.length suffix in
  let raw =
    String.trim
      (String.sub req_path plen (String.length req_path - plen - slen))
  in
  if is_valid_keeper_name raw then raw else ""

let json_int_member_opt name json =
  match Yojson.Safe.Util.member name json with
  | `Int value -> Some value
  | `Intlit raw -> int_of_string_opt raw
  | _ -> None

let json_string_member_opt name json =
  match Yojson.Safe.Util.member name json with
  | `String value -> Some value
  | _ -> None

let json_bool_member_opt name json =
  match Yojson.Safe.Util.member name json with
  | `Bool value -> Some value
  | _ -> None

let json_string_list_member name json =
  match Yojson.Safe.Util.member name json with
  | `List values ->
    values
    |> List.filter_map (function
      | `String value when String.trim value <> "" -> Some value
      | _ -> None)
    |> Json_util.dedupe_keep_order
  | _ -> []

let json_string_opt = function
  | Some value -> `String value
  | None -> `Null

let take_last limit values =
  let len = List.length values in
  if len <= limit then values
  else List.filteri (fun idx _ -> idx >= len - limit) values

let json_assoc_member_opt name json =
  match Yojson.Safe.Util.member name json with
  | `Assoc _ as value -> Some value
  | _ -> None

let json_string_value_opt = function
  | `String value -> Some value
  | _ -> None

let manifest_row_matches ?turn_id keeper_name trace_id
    (row : Keeper_runtime_manifest.t) =
  String.equal row.keeper_name keeper_name
  && String.equal row.trace_id trace_id
  &&
  match turn_id with
  | None -> true
  | Some wanted -> row.keeper_turn_id = Some wanted

let unique_present_paths paths =
  paths
  |> List.filter_map (fun value ->
       match value with
       | Some path when String.trim path <> "" -> Some path
       | _ -> None)
  |> Json_util.dedupe_keep_order

let provider_attempt_row_json (row : Keeper_runtime_manifest.t) =
  let decision_string key = json_string_member_opt key row.decision in
  `Assoc
    [
      ("ts", `String row.ts);
      ("event", `String (Keeper_runtime_manifest.event_kind_to_string row.event));
      ("cascade_name", json_string_opt row.cascade_name);
      ("model_source", json_string_opt (decision_string "model_source"));
      ( "resolved_model_source",
        json_string_opt (decision_string "resolved_model_source") );
      ("capability_source", json_string_opt (decision_string "capability_source"));
      ("fallback_authority", json_string_opt (decision_string "fallback_authority"));
      ( "provider_source_cascade",
        json_string_opt (decision_string "provider_source_cascade") );
      ("status", `String row.status);
      ("error", json_string_opt (decision_string "error"));
      ( "exception_kind",
        json_string_opt (decision_string "exception_kind") );
    ]

let string_contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else if needle_len > haystack_len then false
  else
    let rec loop idx =
      if idx + needle_len > haystack_len then false
      else if String.sub haystack idx needle_len = needle then true
      else loop (idx + 1)
    in
    loop 0

let runtime_trace_keeps_provider_attempt_provenance_key = function
  | "model_source"
  | "resolved_model_source"
  | "capability_source"
  | "fallback_authority"
  | "provider_source_cascade"
  | "terminal_model_source"
  | "terminal_resolved_model_source"
  | "terminal_capability_source"
  | "terminal_fallback_authority"
  | "terminal_provider_source_cascade" ->
    true
  | _ -> false

let runtime_trace_redacts_provider_model_key key =
  let key = String.lowercase_ascii key in
  (not (runtime_trace_keeps_provider_attempt_provenance_key key))
  &&
  (string_contains_substring key "provider"
   || string_contains_substring key "model"
   || String.equal key "configured_labels")

let rec runtime_trace_public_json = function
  | `Assoc fields ->
      `Assoc
        (fields
        |> List.filter_map (fun (key, value) ->
               if runtime_trace_redacts_provider_model_key key then None
               else Some (key, runtime_trace_public_json value)))
  | `List values -> `List (List.map runtime_trace_public_json values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value ->
      value

let tool_call_output_text_opt json =
  match Yojson.Safe.Util.member "output" json with
  | `String value -> Some value
  | `Assoc _ as output -> (
    match json_assoc_member_opt "_blob" output with
    | Some blob -> json_string_member_opt "preview" blob
    | None -> None)
  | _ -> None

let parse_tool_output_json_opt json =
  match tool_call_output_text_opt json with
  | None -> None
  | Some output -> (
    match Safe_ops.parse_json_safe ~context:"runtime_lens.tool_output" output with
    | Ok parsed -> Some parsed
    | Error _ -> None)

let tool_call_runtime_contract json =
  match json_assoc_member_opt "runtime_contract" json with
  | Some contract -> contract
  | None -> `Assoc []

let tool_call_matches_trace ?turn_id ~keeper_name ~trace_id json =
  let contract = tool_call_runtime_contract json in
  let keeper_matches =
    match json_string_member_opt "keeper" json with
    | Some keeper -> String.equal keeper keeper_name
    | None -> true
  in
  let trace_matches =
    match
      ( json_string_member_opt "trace_id" json,
        json_string_member_opt "trace_id" contract )
    with
    | Some value, _ | _, Some value -> String.equal value trace_id
    | None, None -> false
  in
  let turn_matches =
    match turn_id with
    | None -> true
    | Some wanted ->
      json_int_member_opt "keeper_turn_id" json = Some wanted
      || json_int_member_opt "keeper_turn_id" contract = Some wanted
  in
  keeper_matches && trace_matches && turn_matches

let first_string_opt values =
  List.find_map (fun value -> value) values

let first_int_opt values =
  List.find_map (fun value -> value) values

let string_has_prefix ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.equal (String.sub value 0 prefix_len) prefix

let claim_status_of_output output =
  let result =
    match json_string_member_opt "result" output with
    | Some value -> String.trim value
    | None -> ""
  in
  match json_assoc_member_opt "claimed_task" output with
  | Some _ -> "claimed"
  | None when string_has_prefix ~prefix:"No eligible tasks" result -> "no_eligible"
  | None when string_has_prefix ~prefix:"No unclaimed tasks" result -> "no_unclaimed"
  | None when string_has_prefix ~prefix:"Error:" result -> "error"
  | None when result = "" -> "unknown"
  | None -> "observed"

let claim_scope_summary_absent =
  `Assoc
    [ ("present", `Bool false)
    ; ("source", `String "keeper_task_claim_tool_call")
    ; ("status", `String "not_observed")
    ; ("result", `Null)
    ; ("mode", `Null)
    ; ("scoped", `Null)
    ; ("active_goal_ids", `List [])
    ; ("effective_goal_ids", `List [])
    ; ("fallback_reason", `Null)
    ; ("matched_goal_id", `Null)
    ; ("excluded_count", `Null)
    ; ("claimed_task_id", `Null)
    ; ("claimed_goal_id", `Null)
    ; ("trace_id", `Null)
    ; ("keeper_turn_id", `Null)
    ]

let internal_history_json_to_trajectory_line (json : Yojson.Safe.t)
    : Trajectory.trajectory_line option =
  let source = Safe_ops.json_string ~default:"" "source" json in
  let content = Safe_ops.json_string ~default:"" "content" json in
  if source <> "internal_assistant" || String.trim content = "" then None
  else
    let ts =
      match Safe_ops.json_float_opt "ts_unix" json with
      | Some value when value > 0.0 -> value
      | _ ->
          match Safe_ops.json_float_opt "timestamp" json with
          | Some value when value > 0.0 -> value
          | _ -> 0.0
    in
    if ts <= 0.0 then None
    else
      let ts_iso =
        match Safe_ops.json_string_opt "ts_iso" json with
        | Some value when String.trim value <> "" -> value
        | _ ->
            match Safe_ops.json_string_opt "ts" json with
            | Some value when String.trim value <> "" -> value
            | _ -> Dashboard_utils.iso_of_unix ts
      in
      Some
        (Trajectory.Thinking
           {
             ts;
             ts_iso;
             turn = Safe_ops.json_int ~default:0 "turn" json;
             content;
             content_length = String.length content;
             redacted = Safe_ops.json_bool ~default:false "redacted" json;
           })

let runtime_manifest_public_json row =
  Keeper_runtime_manifest.to_json row
  |> runtime_trace_public_json
