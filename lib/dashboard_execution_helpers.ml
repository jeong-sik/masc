type queue_context = {
  severity_rank : int;
  last_seen_ts : float;
  json : Yojson.Safe.t;
}

type session_seed = {
  session_id : string;
  goal : string;
  room : string option;
  status : string;
  health : string;
  member_names : string list;
  last_activity_at : string option;
  last_activity_ts : float;
  last_activity_summary : string;
  communication_summary : string;
  active_count : int;
  seen_count : int;
  planned_count : int;
  required_count : int;
  counts_basis : string;
  runtime_blocker : string option;
  worker_gap_summary : string option;
  top_attention : Yojson.Safe.t option;
  top_recommendation : Yojson.Safe.t option;
}

type session_context = {
  session_id : string;
  severity : string;
  last_seen_ts : float;
  linked_operation_id : string option;
  member_names : string list;
  json : Yojson.Safe.t;
}

type operation_context = {
  operation_id : string;
  severity : string;
  last_seen_ts : float;
  linked_session_id : string option;
  linked_detachment_id : string option;
  json : Yojson.Safe.t;
}

type worker_context = {
  tone_rank : int;
  last_signal_ts : float;
  related_session_id : string option;
  json : Yojson.Safe.t;
}

type continuity_context = {
  tone_rank : int;
  last_signal_ts : float;
  related_session_id : string option;
  json : Yojson.Safe.t;
}

type tool_audit_snapshot = {
  allowed_tool_names : string list;
  latest_tool_names : string list;
  latest_tool_call_count : int option;
  tool_audit_source : string option;
  tool_audit_at : string option;
}

let json_string_option value =
  match value with
  | Some text when String.trim text <> "" -> `String (String.trim text)
  | _ -> `Null

let option_or_else fallback = function
  | Some _ as value -> value
  | None -> fallback ()

let option_to_json f = function
  | Some value -> f value
  | None -> `Null

let member_assoc key json =
  match json with
  | `Assoc fields -> (match List.assoc_opt key fields with Some value -> value | None -> `Null)
  | _ -> `Null

let string_field ?(default = "") key json =
  match member_assoc key json with
  | `String value -> value
  | _ -> default

let int_field ?(default = 0) key json =
  match member_assoc key json with
  | `Int value -> value
  | `Intlit raw -> (try int_of_string raw with Failure _ -> default)
  | `Float value -> int_of_float value
  | _ -> default

let list_field key json =
  match member_assoc key json with
  | `List items -> items
  | _ -> []

let trim_to_option = Dashboard_utils.trim_to_option

let compact_text ?(max_len = 160) raw =
  let normalized =
    String.trim raw
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun value -> value <> "")
    |> String.concat " "
    |> String.trim
  in
  if normalized = "" then ""
  else if String.length normalized <= max_len then normalized
  else String.sub normalized 0 (max_len - 1) ^ "…"

let parse_iso_opt = Dashboard_utils.parse_iso_opt
let string_list_of_json = Dashboard_utils.string_list_of_json

let string_list_json values =
  `List (List.map (fun value -> `String value) values)

let string_list_of_field key json =
  member_assoc key json |> string_list_of_json

let tool_audit_snapshot agent_name =
  let task_snapshot = A2a_tools.latest_heartbeat_task agent_name in
  let result_snapshot = A2a_tools.latest_heartbeat_result agent_name in
  match task_snapshot, result_snapshot with
  | Some task, Some result when task.seq > result.seq ->
      {
        allowed_tool_names = task.allowed_tools;
        latest_tool_names = [];
        latest_tool_call_count = None;
        tool_audit_source = Some "heartbeat_task";
        tool_audit_at = Some task.created_at;
      }
  | Some task, Some result ->
      {
        allowed_tool_names = task.allowed_tools;
        latest_tool_names = result.tool_names;
        latest_tool_call_count = Some result.tool_call_count;
        tool_audit_source = Some "heartbeat_result";
        tool_audit_at = Some result.updated_at;
      }
  | Some task, None ->
      {
        allowed_tool_names = task.allowed_tools;
        latest_tool_names = [];
        latest_tool_call_count = None;
        tool_audit_source = Some "heartbeat_task";
        tool_audit_at = Some task.created_at;
      }
  | None, Some result ->
      {
        allowed_tool_names = [];
        latest_tool_names = result.tool_names;
        latest_tool_call_count = Some result.tool_call_count;
        tool_audit_source = Some "heartbeat_result";
        tool_audit_at = Some result.updated_at;
      }
  | None, None ->
      {
        allowed_tool_names = [];
        latest_tool_names = [];
        latest_tool_call_count = None;
        tool_audit_source = None;
        tool_audit_at = None;
      }

let skill_route_summary_of_keeper keeper =
  let route = member_assoc "skill_route" keeper in
  let primary =
    trim_to_option (string_field "primary" route)
    |> option_or_else (fun () -> trim_to_option (string_field "skill_primary" keeper))
  in
  let secondary =
    let route_secondary = string_list_of_field "secondary" route in
    if route_secondary <> [] then route_secondary
    else string_list_of_field "skill_secondary" keeper
  in
  let provenance = trim_to_option (string_field "provenance" route) in
  match primary, secondary, provenance with
  | None, [], None -> None
  | Some value, [], None -> Some value
  | Some value, [], Some source -> Some (Printf.sprintf "%s · %s" value source)
  | Some value, extra, source ->
      let extra_summary =
        if extra = [] then None else Some (Printf.sprintf "+%d" (List.length extra))
      in
      Some
        (String.concat " · "
           (List.filter_map (fun item -> item) [ Some value; extra_summary; source ]))
  | None, extra, source ->
      Some
        (String.concat " · "
           (List.filter_map
              (fun item -> item)
              [
                (if extra = [] then None else Some (Printf.sprintf "%d route(s)" (List.length extra)));
                source;
              ]))

let dedup_strings items =
  List.sort_uniq String.compare
    (List.filter_map trim_to_option items)

let severity_rank = function
  | "bad" | "critical" | "failed" -> 2
  | "warn" | "blocked" | "paused" | "interrupted" -> 1
  | _ -> 0

let tone_rank = function
  | "bad" -> 2
  | "warn" -> 1
  | _ -> 0

let dashboard_fixture_name ?fixture () =
  match fixture with
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> (
      match Sys.getenv_opt "MASC_DASHBOARD_FIXTURE" with
      | Some value when String.trim value <> "" -> Some (String.trim value)
      | _ -> None)

let get_agent_identity (name : string) =
  let contains s sub =
    let len = String.length s in
    let sub_len = String.length sub in
    if sub_len > len then false
    else
      let rec loop i =
        if i + sub_len > len then false
        else if String.sub s i sub_len = sub then true
        else loop (i + 1)
      in
      loop 0
  in
  let normalized = String.lowercase_ascii name in
  if contains normalized "claude" then ("🧠", "클로드")
  else if contains normalized "gemini" then ("💎", "제미나이")
  else if contains normalized "codex" then ("🤖", "코덱스")
  else if contains normalized "lodge" then ("🏠", "롯지 키퍼")
  else if contains normalized "gardener" then ("🌿", "정원사")
  else if contains normalized "review" then ("🔍", "리뷰어")
  else if contains normalized "test" then ("🧪", "테스터")
  else ("🤖", name)

let handoff_json ~surface ?command_surface ?operation_id ~label ~target_type ~target_id
    ~focus_kind () =
  `Assoc
    ([
       ("surface", `String surface);
       ("label", `String label);
       ("target_type", `String target_type);
       ("target_id", `String target_id);
       ("focus_kind", `String focus_kind);
     ]
    @
    match command_surface with
    | Some value -> [ ("command_surface", `String value) ]
    | None -> []
    @
    match operation_id with
    | Some value -> [ ("operation_id", `String value) ]
    | None -> [])

