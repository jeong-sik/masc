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

let execution_smoke_fixture_json () =
  let generated_at = Types.now_iso () in
  let intervene_handoff =
    handoff_json
      ~surface:"intervene"
      ~label:"세션 개입 열기"
      ~target_type:"team_session"
      ~target_id:"ts-execution-fixture-001"
      ~focus_kind:"team_session"
      ()
  in
  let command_handoff =
    handoff_json
      ~surface:"command"
      ~command_surface:"operations"
      ~operation_id:"op-runtime-001"
      ~label:"작전 원인 보기"
      ~target_type:"team_session"
      ~target_id:"ts-execution-fixture-001"
      ~focus_kind:"operation"
      ()
  in
  let operation_handoff =
    handoff_json
      ~surface:"command"
      ~command_surface:"operations"
      ~operation_id:"op-runtime-002"
      ~label:"작전 원인 보기"
      ~target_type:"operation"
      ~target_id:"op-runtime-002"
      ~focus_kind:"operation"
      ()
  in
  `Assoc
    [
      ("generated_at", `String generated_at);
      ( "status",
        `Assoc
          [
            ("room", `String "default");
            ("room_base_path", `String "/tmp/masc-execution-fixture");
            ("cluster", `String "fixture");
            ("project", `String "execution-smoke");
            ("tempo_interval_s", `Float 300.0);
            ("paused", `Bool false);
            ("lodge", `Assoc []);
            ( "social_runtime",
              `Assoc
                [
                  ("enabled", `Bool true);
                  ("strategy", `String "event_driven");
                  ("queue_depth", `Int 0);
                  ("active_keepers", `Int 2);
                  ("last_pass_reason", `String "stayed read-only after evaluating the board");
                  ("last_system_skip_reason", `String "rate-limited after a recent board action");
                ] );
            ("version", `String Version.version);
          ] );
      ( "social_tick",
        `Assoc
          [
            ("checked", `Int 3);
            ("acted", `Int 1);
            ("passed", `Int 1);
            ("skipped", `Int 1);
            ("failed", `Int 0);
            ("last_tick_at", `String generated_at);
            ("last_pass_reason", `String "stayed read-only after evaluating the board");
            ("last_system_skip_reason", `String "rate-limited after a recent board action");
            ("strategy", `String "event_driven");
            ("queue_depth", `Int 0);
            ("activity_report", `String "alpha acted, beta passed, gamma skipped");
          ] );
      ( "social_checkins",
        `List
          [
            `Assoc
              [
                ("agent_name", `String "dreamer");
                ("trigger", `String "scheduled");
                ("outcome", `String "acted");
                ("summary", `String "posted a runtime note to the board");
                ("reason", `String "runtime pressure on the board justified a post");
                ("allowed_tool_names", `List [ `String "masc_board_get"; `String "masc_board_list"; `String "masc_board_post"; `String "lodge_search" ]);
                ("used_tool_names", `List [ `String "masc_board_post" ]);
                ("used_tool_call_count", `Int 1);
                ("action_kind", `String "post");
                ("tool_audit_source", `String "heartbeat_result");
                ("tool_audit_at", `String generated_at);
                ("checked_at", `String generated_at);
                ("decision_reason", `String "critical board state required intervention");
                ("worker_name", `String "llama-local-dreamer");
                ("failure_reason", `Null);
              ];
            `Assoc
              [
                ("agent_name", `String "historian");
                ("trigger", `String "scheduled");
                ("outcome", `String "passed");
                ("summary", `Null);
                ("reason", `String "stayed read-only after evaluating the board");
                ("allowed_tool_names", `List [ `String "masc_board_get"; `String "masc_board_list"; `String "lodge_profile"; `String "lodge_research" ]);
                ("used_tool_names", `List []);
                ("used_tool_call_count", `Null);
                ("action_kind", `String "none");
                ("tool_audit_source", `String "heartbeat_task");
                ("tool_audit_at", `String generated_at);
                ("checked_at", `String generated_at);
                ("decision_reason", `String "not enough evidence to post");
                ("worker_name", `Null);
                ("failure_reason", `Null);
              ];
            `Assoc
              [
                ("agent_name", `String "connector");
                ("trigger", `String "scheduled");
                ("outcome", `String "skipped");
                ("summary", `Null);
                ("reason", `String "rate-limited after a recent board action");
                ("allowed_tool_names", `List []);
                ("used_tool_names", `List []);
                ("used_tool_call_count", `Null);
                ("action_kind", `String "none");
                ("tool_audit_source", `Null);
                ("tool_audit_at", `Null);
                ("checked_at", `String generated_at);
                ("decision_reason", `Null);
                ("worker_name", `Null);
                ("failure_reason", `Null);
              ];
          ] );
      ( "lodge_tick",
        `Assoc
          [
            ("checked", `Int 3);
            ("acted", `Int 1);
            ("passed", `Int 1);
            ("skipped", `Int 1);
            ("failed", `Int 0);
            ("last_tick_at", `String generated_at);
            ("last_skip_reason", `String "rate-limited after a recent board action");
            ("last_pass_reason", `String "stayed read-only after evaluating the board");
            ("last_system_skip_reason", `String "rate-limited after a recent board action");
            ("strategy", `String "event_driven");
            ("queue_depth", `Int 0);
            ("activity_report", `String "alpha acted, beta passed, gamma skipped");
          ] );
      ( "lodge_checkins",
        `List
          [
            `Assoc
              [
                ("agent_name", `String "dreamer");
                ("trigger", `String "scheduled");
                ("outcome", `String "acted");
                ("summary", `String "posted a runtime note to the board");
                ("reason", `String "runtime pressure on the board justified a post");
                ("allowed_tool_names", `List [ `String "masc_board_get"; `String "masc_board_list"; `String "masc_board_post"; `String "lodge_search" ]);
                ("used_tool_names", `List [ `String "masc_board_post" ]);
                ("used_tool_call_count", `Int 1);
                ("action_kind", `String "post");
                ("tool_audit_source", `String "heartbeat_result");
                ("tool_audit_at", `String generated_at);
                ("checked_at", `String generated_at);
                ("decision_reason", `String "critical board state required intervention");
                ("worker_name", `String "llama-local-dreamer");
                ("failure_reason", `Null);
              ];
            `Assoc
              [
                ("agent_name", `String "historian");
                ("trigger", `String "scheduled");
                ("outcome", `String "passed");
                ("summary", `Null);
                ("reason", `String "stayed read-only after evaluating the board");
                ("allowed_tool_names", `List [ `String "masc_board_get"; `String "masc_board_list"; `String "lodge_profile"; `String "lodge_research" ]);
                ("used_tool_names", `List []);
                ("used_tool_call_count", `Null);
                ("action_kind", `String "none");
                ("tool_audit_source", `String "heartbeat_task");
                ("tool_audit_at", `String generated_at);
                ("checked_at", `String generated_at);
                ("decision_reason", `String "not enough evidence to post");
                ("worker_name", `Null);
                ("failure_reason", `Null);
              ];
            `Assoc
              [
                ("agent_name", `String "connector");
                ("trigger", `String "scheduled");
                ("outcome", `String "skipped");
                ("summary", `Null);
                ("reason", `String "rate-limited after a recent board action");
                ("allowed_tool_names", `List []);
                ("used_tool_names", `List []);
                ("used_tool_call_count", `Null);
                ("action_kind", `String "none");
                ("tool_audit_source", `Null);
                ("tool_audit_at", `Null);
                ("checked_at", `String generated_at);
                ("decision_reason", `Null);
                ("worker_name", `Null);
                ("failure_reason", `Null);
              ];
          ] );
      ( "execution_queue",
        `List
          [
            `Assoc
              [
                ("id", `String "session-ts-execution-fixture-001");
                ("kind", `String "session");
                ("severity", `String "bad");
                ("status", `String "interrupted");
                ("summary", `String "session has 2 failed spawn event(s)");
                ("target_type", `String "team_session");
                ("target_id", `String "ts-execution-fixture-001");
                ("linked_session_id", `String "ts-execution-fixture-001");
                ("linked_operation_id", `String "op-runtime-001");
                ("last_seen_at", `String generated_at);
                ("top_handoff", intervene_handoff);
                ("intervene_handoff", intervene_handoff);
                ("command_handoff", command_handoff);
              ];
            `Assoc
              [
                ("id", `String "operation-op-runtime-002");
                ("kind", `String "operation");
                ("severity", `String "warn");
                ("status", `String "active");
                ("summary", `String "Waiting on upstream checkpoint before verify stage");
                ("target_type", `String "operation");
                ("target_id", `String "op-runtime-002");
                ("linked_session_id", `Null);
                ("linked_operation_id", `String "op-runtime-002");
                ("last_seen_at", `String generated_at);
                ("top_handoff", operation_handoff);
                ("intervene_handoff", `Null);
                ("command_handoff", operation_handoff);
              ];
          ] );
      ( "priority_queue",
        `List
          [
            `Assoc
              [
                ("id", `String "session-ts-execution-fixture-001");
                ("kind", `String "session");
                ("tone", `String "bad");
                ("title", `String "ts-execution-fixture-001");
                ("subtitle", `String "session has 2 failed spawn event(s)");
                ("timestamp", `String generated_at);
                ("target_type", `String "team_session");
                ("target_id", `String "ts-execution-fixture-001");
              ];
            `Assoc
              [
                ("id", `String "operation-op-runtime-002");
                ("kind", `String "operation");
                ("tone", `String "warn");
                ("title", `String "op-runtime-002");
                ("subtitle", `String "Waiting on upstream checkpoint before verify stage");
                ("timestamp", `String generated_at);
                ("target_type", `String "operation");
                ("target_id", `String "op-runtime-002");
              ];
          ] );
      ( "session_briefs",
        `List
          [
            `Assoc
              [
                ("session_id", `String "ts-execution-fixture-001");
                ("goal", `String "Validate local64 swarm role coverage, runtime visibility, and operator census");
                ("room", `String "default");
                ("status", `String "interrupted");
                ("health", `String "bad");
                ("member_names", `List [ `String "llama-local-alpha"; `String "llama-local-beta"; `String "llama-local-delta" ]);
                ("linked_operation_id", `String "op-runtime-001");
                ("linked_detachment_id", `String "det-runtime-001");
                ("runtime_blocker", `String "session has 2 failed spawn event(s)");
                ("worker_gap_summary", `String "Recover failed worker coverage");
                ("last_activity_at", `String generated_at);
                ("last_activity_summary", `String "local64 smoke cleanup");
                ("communication_summary", `String "hybrid · broadcast 0 · portal 0");
                ("active_count", `Int 3);
                ("seen_count", `Int 3);
                ("planned_count", `Int 4);
                ("required_count", `Int 1);
                ("counts_basis", `String "live=recent_turns · planned=roster");
                ("top_handoff", intervene_handoff);
                ("intervene_handoff", intervene_handoff);
                ("command_handoff", command_handoff);
              ];
            `Assoc
              [
                ("session_id", `String "ts-execution-fixture-002");
                ("goal", `String "Monitor runtime pressure without intervention");
                ("room", `String "default");
                ("status", `String "running");
                ("health", `String "ok");
                ("member_names", `List [ `String "llama-local-gamma" ]);
                ("linked_operation_id", `String "op-runtime-003");
                ("linked_detachment_id", `String "det-runtime-003");
                ("runtime_blocker", `Null);
                ("worker_gap_summary", `Null);
                ("last_activity_at", `String generated_at);
                ("last_activity_summary", `String "healthy runtime census");
                ("communication_summary", `String "hybrid · broadcast 1 · portal 0");
                ("active_count", `Int 1);
                ("seen_count", `Int 1);
                ("planned_count", `Int 1);
                ("required_count", `Int 1);
                ("counts_basis", `String "live=recent_turns · planned=roster");
                ("top_handoff", command_handoff);
                ("intervene_handoff", intervene_handoff);
                ("command_handoff", command_handoff);
              ];
          ] );
      ( "operation_briefs",
        `List
          [
            `Assoc
              [
                ("operation_id", `String "op-runtime-001");
                ("objective", `String "Validate local64 swarm role coverage");
                ("status", `String "active");
                ("stage", `String "verify");
                ("assigned_unit_id", `String "squad-runtime");
                ("assigned_unit_label", `String "Runtime Squad");
                ("linked_session_id", `String "ts-execution-fixture-001");
                ("linked_detachment_id", `String "det-runtime-001");
                ("blocker_summary", `String "session has 2 failed spawn event(s)");
                ("search_status", `String "blocked");
                ("next_tool", `String "masc_team_session_events");
                ("updated_at", `String generated_at);
                ("top_handoff", command_handoff);
                ("command_handoff", command_handoff);
              ];
            `Assoc
              [
                ("operation_id", `String "op-runtime-002");
                ("objective", `String "Audit dependency blockers before verify stage");
                ("status", `String "active");
                ("stage", `String "verify");
                ("assigned_unit_id", `String "squad-review");
                ("assigned_unit_label", `String "Review Squad");
                ("linked_session_id", `Null);
                ("linked_detachment_id", `Null);
                ("blocker_summary", `String "Waiting on upstream checkpoint before verify stage");
                ("search_status", `String "blocked");
                ("next_tool", `String "masc_operation_status");
                ("updated_at", `String generated_at);
                ("top_handoff", operation_handoff);
                ("command_handoff", operation_handoff);
              ];
          ] );
      ( "worker_support_briefs",
        `List
          [
            `Assoc
              [
                ("name", `String "llama-local-alpha");
                ("agent_name", `String "llama-local-alpha");
                ("status", `String "busy");
                ("tone", `String "ok");
                ("state", `String "working");
                ("note", `String "Task and live signal aligned");
                ("focus", `String "Validate local64 swarm role coverage");
                ("last_signal_at", `String generated_at);
                ("last_signal_age_sec", `Int 18);
                ("signal_truth", `String "live");
                ("evidence_source", `String "message");
                ("active_task_count", `Int 1);
                ("related_session_id", `String "ts-execution-fixture-001");
                ("related_operation_id", `String "op-runtime-001");
                ("emoji", `String "🤖");
                ("korean_name", `String "llama-local-alpha");
                ("model", `String Env_config.Llama.default_model);
                ("recent_output_preview", `String "manager synthesized runtime visibility and handed next checks to beta");
                ("recent_event", `String "manager handoff");
              ];
            `Assoc
              [
                ("name", `String "llama-local-beta");
                ("agent_name", `String "llama-local-beta");
                ("status", `String "active");
                ("tone", `String "warn");
                ("state", `String "quiet");
                ("note", `String "Execution looks quiet for too long");
                ("focus", `String "Inspect secondary runtime health");
                ("last_signal_at", `String "2026-03-11T09:15:00Z");
                ("last_signal_age_sec", `Int 780);
                ("signal_truth", `String "stale");
                ("evidence_source", `String "message");
                ("active_task_count", `Int 1);
                ("related_session_id", `String "ts-execution-fixture-001");
                ("related_operation_id", `String "op-runtime-001");
                ("emoji", `String "🤖");
                ("korean_name", `String "llama-local-beta");
                ("model", `String "qwen27-balanced");
                ("recent_output_preview", `String "secondary runtime is quiet; watching queue depth before escalation");
                ("recent_event", `String "secondary runtime probe");
              ];
            `Assoc
              [
                ("name", `String "llama-local-gamma");
                ("agent_name", `String "llama-local-gamma");
                ("status", `String "idle");
                ("tone", `String "ok");
                ("state", `String "watching");
                ("note", `String "Standing by for the next task");
                ("focus", `String "Idle / waiting for assignment");
                ("last_signal_at", `String generated_at);
                ("last_signal_age_sec", `Int 12);
                ("signal_truth", `String "live");
                ("evidence_source", `String "presence");
                ("active_task_count", `Int 0);
                ("related_session_id", `String "ts-execution-fixture-002");
                ("related_operation_id", `String "op-runtime-003");
                ("emoji", `String "🤖");
                ("korean_name", `String "llama-local-gamma");
                ("model", `String "qwen9-swarm");
                ("recent_output_preview", `Null);
                ("recent_event", `String "idle");
              ];
          ] );
      ( "worker_briefs",
        `List
          [
            `Assoc
              [
                ("name", `String "llama-local-alpha");
                ("agent_name", `String "llama-local-alpha");
                ("status", `String "busy");
                ("tone", `String "ok");
                ("state", `String "working");
                ("note", `String "Task and live signal aligned");
                ("focus", `String "Validate local64 swarm role coverage");
                ("last_signal_at", `String generated_at);
                ("last_signal_age_sec", `Int 18);
                ("signal_truth", `String "live");
                ("evidence_source", `String "message");
                ("active_task_count", `Int 1);
              ];
            `Assoc
              [
                ("name", `String "llama-local-beta");
                ("agent_name", `String "llama-local-beta");
                ("status", `String "active");
                ("tone", `String "warn");
                ("state", `String "quiet");
                ("note", `String "Execution looks quiet for too long");
                ("focus", `String "Inspect secondary runtime health");
                ("last_signal_at", `String "2026-03-11T09:15:00Z");
                ("last_signal_age_sec", `Int 780);
                ("signal_truth", `String "stale");
                ("evidence_source", `String "message");
                ("active_task_count", `Int 1);
              ];
          ] );
      ( "continuity_briefs",
        `List
          [
            `Assoc
              [
                ("name", `String "dm-keeper");
                ("agent_name", `String "dm-keeper");
                ("status", `String "active");
                ("tone", `String "bad");
                ("state", `String "critical");
                ("note", `String "핸드오프 임박");
                ("focus", `String "masc-keeper-autonomy");
                ("last_signal_at", `String generated_at);
                ("last_autonomous_action_at", `String generated_at);
                ("generation", `Int 2);
                ("turn_count", `Int 84);
                ("context_ratio", `Float 0.91);
                ("continuity", `String "Gen 2 · Turns 84 · Goals 2");
                ("lifecycle", `String "handoff-imminent");
                ("related_session_id", `Null);
                ("model", `String "qwen27-balanced");
                ("emoji", `String "🤖");
                ("korean_name", `String "dm-keeper");
                ("recent_input_preview", `String "Player asked to continue the next scene without breaking continuity");
                ("recent_output_preview", `String "Prepared the next scene transition and handoff summary");
                ("recent_tool_names", `List [ `String "masc_keeper_status"; `String "masc_board_post" ]);
                ("allowed_tool_names", `List [ `String "masc_board_get"; `String "masc_board_post"; `String "masc_keeper_status" ]);
                ("latest_tool_names", `List [ `String "masc_board_post" ]);
                ("latest_tool_call_count", `Int 1);
                ("tool_audit_source", `String "heartbeat_result");
                ("tool_audit_at", `String generated_at);
                ("last_proactive_preview", `String "Summarized the next scene handoff");
                ("continuity_summary", `String "Continuity pressure is high; handoff prep is underway");
                ("skill_route_summary", `String "scene-director · +1 · judgment");
              ];
          ] );
      ( "offline_worker_briefs",
        `List
          [
            `Assoc
              [
                ("name", `String "llama-local-delta");
                ("agent_name", `String "llama-local-delta");
                ("status", `String "inactive");
                ("tone", `String "bad");
                ("state", `String "offline");
                ("note", `String "Offline or inactive");
                ("focus", `String "Recover worker before reassigning");
                ("last_signal_at", `String "2026-03-11T08:55:00Z");
                ("last_signal_age_sec", `Int 1200);
                ("signal_truth", `String "absent");
                ("evidence_source", `String "none");
                ("active_task_count", `Int 0);
                ("related_session_id", `String "ts-execution-fixture-001");
                ("related_operation_id", `String "op-runtime-001");
                ("emoji", `String "🤖");
                ("korean_name", `String "llama-local-delta");
                ("model", `String "qwen9-swarm");
                ("recent_output_preview", `Null);
                ("recent_event", `String "missing heartbeat");
              ];
          ] );
      ( "agents",
        `List
          [
            `Assoc
              [
                ("name", `String "llama-local-alpha");
                ("agent_type", `String "llama");
                ("status", `String "busy");
                ("current_task", `String "Validate local64 swarm role coverage");
                ("joined_at", `String generated_at);
                ("last_seen", `String generated_at);
                ("capabilities", `List [ `String "manager"; `String "local64" ]);
                ("emoji", `String "🤖");
                ("koreanName", `String "llama-local-alpha");
              ];
            `Assoc
              [
                ("name", `String "llama-local-beta");
                ("agent_type", `String "llama");
                ("status", `String "active");
                ("current_task", `String "Inspect secondary runtime health");
                ("joined_at", `String generated_at);
                ("last_seen", `String "2026-03-11T09:15:00Z");
                ("capabilities", `List [ `String "metacog"; `String "local64" ]);
                ("emoji", `String "🤖");
                ("koreanName", `String "llama-local-beta");
              ];
            `Assoc
              [
                ("name", `String "llama-local-gamma");
                ("agent_type", `String "llama");
                ("status", `String "idle");
                ("current_task", `Null);
                ("joined_at", `String generated_at);
                ("last_seen", `String generated_at);
                ("capabilities", `List [ `String "executor"; `String "local64" ]);
                ("emoji", `String "🤖");
                ("koreanName", `String "llama-local-gamma");
              ];
            `Assoc
              [
                ("name", `String "llama-local-delta");
                ("agent_type", `String "llama");
                ("status", `String "inactive");
                ("current_task", `Null);
                ("joined_at", `String generated_at);
                ("last_seen", `String "2026-03-11T08:55:00Z");
                ("capabilities", `List [ `String "observer"; `String "local64" ]);
                ("emoji", `String "🤖");
                ("koreanName", `String "llama-local-delta");
              ];
          ] );
      ( "tasks",
        `List
          [
            `Assoc
              [
                ("id", `String "task-local64-001");
                ("title", `String "Validate local64 swarm role coverage");
                ("description", `String "manager census and runtime visibility");
                ("status", `String "in_progress");
                ("priority", `Int 1);
                ("assignee", `String "llama-local-alpha");
                ("created_at", `String generated_at);
              ];
            `Assoc
              [
                ("id", `String "task-local64-002");
                ("title", `String "Inspect secondary runtime health");
                ("description", `String "probe quiet worker path");
                ("status", `String "claimed");
                ("priority", `Int 2);
                ("assignee", `String "llama-local-beta");
                ("created_at", `String generated_at);
              ];
            `Assoc
              [
                ("id", `String "task-local64-003");
                ("title", `String "Recover worker before reassigning");
                ("description", `String "pending observer replacement");
                ("status", `String "todo");
                ("priority", `Int 2);
                ("assignee", `Null);
                ("created_at", `String generated_at);
              ];
          ] );
      ( "messages",
        `List
          [
            `Assoc
              [
                ("from", `String "llama-local-alpha");
                ("content", `String "manager synthesized runtime visibility and handed next checks to beta");
                ("timestamp", `String generated_at);
                ("seq", `Int 1);
              ];
            `Assoc
              [
                ("from", `String "llama-local-beta");
                ("content", `String "secondary runtime is quiet; watching queue depth before escalation");
                ("timestamp", `String "2026-03-11T09:15:00Z");
                ("seq", `Int 2);
              ];
          ] );
      ( "keepers",
        `List
          [
            `Assoc
              [
                ("name", `String "dm-keeper");
                ("agent_name", `String "dm-keeper");
                ("status", `String "active");
                ("generation", `Int 2);
                ("turn_count", `Int 84);
                ("context_ratio", `Float 0.91);
                ("context_tokens", `Int 245000);
                ("last_autonomous_action_at", `String generated_at);
                ("autonomous_action_count", `Int 11);
                ("active_goal_ids", `List [ `String "goal-runtime"; `String "goal-story" ]);
                ("model", `String "qwen27-balanced");
                ("active_model", `String "qwen27-balanced");
                ("goal", `String "masc-keeper-autonomy");
                ("short_goal", `String "masc-keeper-autonomy");
                ("updated_at", `String generated_at);
                ("created_at", `String generated_at);
              ];
          ] );
    ]

let room_status_json (config : Room.config) : Yojson.Safe.t =
  let room_state_opt =
    if Room.is_initialized config then Some (Room.read_state config) else None
  in
  let current_room = Room.current_room_id config in
  let project =
    match room_state_opt with
    | Some room_state -> room_state.project
    | None -> "default"
  in
  let paused =
    match room_state_opt with
    | Some room_state -> room_state.paused
    | None -> false
  in
  let tempo = Tempo.get_tempo config in
  let lodge_json = Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  let social_runtime_json = Social_runtime.status_json ~config in
  `Assoc
    [
      ("room", `String current_room);
      ("room_base_path", `String config.base_path);
      ("cluster", `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME")));
      ("project", `String project);
      ("current_room", `String current_room);
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool paused);
      ("lodge", lodge_json);
      ("social_runtime", social_runtime_json);
      ("version", `String Version.version);
    ]

let current_room_id config =
  Room.current_room_id config

let tasks_safe config =
  if Room.is_initialized config then Room.get_tasks_raw_in_room config (current_room_id config)
  else []

let agents_safe config =
  if Room.is_initialized config then Room.get_agents_raw_in_room config (current_room_id config)
  else []

let messages_safe config =
  if Room.is_initialized config then
    Room.get_messages_raw_in_room config ~room_id:(current_room_id config) ~since_seq:0
      ~limit:50
  else []

let task_assignee (task : Types.task) =
  match task.task_status with
  | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } ->
      Some assignee
  | Todo | Cancelled _ -> None

let task_json (task : Types.task) =
  `Assoc
    [
      ("id", `String task.id);
      ("title", `String task.title);
      ("description", `String task.description);
      ("status", `String (Types.string_of_task_status task.task_status));
      ("priority", `Int task.priority);
      ("assignee", (match task_assignee task with Some value -> `String value | None -> `Null));
      ("created_at", `String task.created_at);
    ]

let agent_json (agent : Types.agent) =
  let (emoji, korean_name) = get_agent_identity agent.name in
  `Assoc
    [
      ("name", `String agent.name);
      ("agent_type", `String agent.agent_type);
      ("status", `String (Types.string_of_agent_status agent.status));
      ( "current_task",
        match agent.current_task with
        | Some task -> `String task
        | None -> `Null );
      ("joined_at", `String agent.joined_at);
      ("last_seen", `String agent.last_seen);
      ("capabilities", `List (List.map (fun value -> `String value) agent.capabilities));
      ("emoji", `String emoji);
      ("koreanName", `String korean_name);
      ("model", `Null);
    ]

let message_json (message : Types.message) =
  `Assoc
    [
      ("from", `String message.from_agent);
      ("content", `String message.content);
      ("timestamp", `String message.timestamp);
      ("seq", `Int message.seq);
    ]

let last_message_map messages =
  let table = Hashtbl.create 32 in
  List.iter
    (fun (message : Types.message) ->
      let key = String.lowercase_ascii (String.trim message.from_agent) in
      let ts = Types.parse_iso8601 message.timestamp in
      match Hashtbl.find_opt table key with
      | Some (existing_ts, _) when existing_ts >= ts -> ()
      | _ -> Hashtbl.replace table key (ts, message))
    messages;
  table

let active_task_count tasks agent_name =
  List.fold_left
    (fun acc (task : Types.task) ->
      match task.task_status, task_assignee task with
      | (Claimed _ | InProgress _), Some assignee when assignee = agent_name -> acc + 1
      | _ -> acc)
    0 tasks

let worker_state_of_agent
    ~(now_ts : float)
    ~(messages_by_agent : (string, float * Types.message) Hashtbl.t)
    ~(tasks : Types.task list)
    ?related_session_id ?related_operation_id
    (agent : Types.agent) : worker_context =
  let key = String.lowercase_ascii (String.trim agent.name) in
  let message_opt = Hashtbl.find_opt messages_by_agent key in
  let last_seen_ts =
    parse_iso_opt (trim_to_option agent.last_seen) |> Option.value ~default:0.0
  in
  let last_message_ts =
    match message_opt with
    | Some (ts, _) -> ts
    | None -> 0.0
  in
  let last_signal_ts = Float.max last_seen_ts last_message_ts in
  let last_signal_at =
    if last_signal_ts <= 0.0 then None
    else if last_message_ts >= last_seen_ts then
      match message_opt with
      | Some (_, message) -> trim_to_option message.timestamp
      | None -> trim_to_option agent.last_seen
    else
      trim_to_option agent.last_seen
  in
  let signal_age_s =
    if last_signal_ts > 0.0 then max 0.0 (now_ts -. last_signal_ts)
    else infinity
  in
  let signal_truth =
    if last_signal_ts <= 0.0 then
      "absent"
    else if signal_age_s <= 300.0 then
      "live"
    else
      "stale"
  in
  let evidence_source =
    if last_message_ts > 0.0 && last_message_ts >= last_seen_ts then
      "message"
    else if last_seen_ts > 0.0 then
      "presence"
    else
      "none"
  in
  let active_task_count = active_task_count tasks agent.name in
  let recent_output_preview =
    match message_opt with
    | Some (_, message) -> trim_to_option (compact_text message.content)
    | None -> None
  in
  let has_work =
    Option.is_some (trim_to_option (Option.value ~default:"" agent.current_task))
    || active_task_count > 0
  in
  let status_string = Types.string_of_agent_status agent.status in
  let (state, tone, note) =
    match agent.status with
    | Types.Inactive ->
        ( "offline",
          "bad",
          if last_signal_ts > 0.0 then "Offline or inactive" else "No recent presence" )
    | Types.Busy | Types.Active | Types.Listening ->
        if signal_age_s > 1200.0 then
          ( "quiet",
            "bad",
            if has_work then "Working without a fresh signal" else "No fresh agent signal" )
        else if has_work then
          if signal_age_s > 600.0 then
            ("quiet", "warn", "Execution looks quiet for too long")
          else
            ("working", "ok", "Task and live signal aligned")
        else if signal_age_s > 600.0 then
          ("quiet", "warn", "Quiet but still reachable")
        else
          ("watching", "ok", "Standing by for the next task")
  in
  let focus =
    match trim_to_option (Option.value ~default:"" agent.current_task) with
    | Some value -> value
    | None ->
        if active_task_count > 0 then
          Printf.sprintf "%d claimed tasks waiting for explicit current_task"
            active_task_count
        else
          Option.value ~default:"Idle / waiting for assignment" recent_output_preview
  in
  let (emoji, korean_name) = get_agent_identity agent.name in
  {
    tone_rank = tone_rank tone;
    last_signal_ts;
    related_session_id;
    json =
      `Assoc
        [
          ("name", `String agent.name);
          ("agent_name", `String agent.name);
          ("status", `String status_string);
          ("tone", `String tone);
          ("state", `String state);
          ("note", `String note);
          ("focus", `String focus);
          ("last_signal_at", json_string_option last_signal_at);
          ("last_signal_age_sec", if Float.is_finite signal_age_s then `Int (int_of_float signal_age_s) else `Null);
          ("signal_truth", `String signal_truth);
          ("evidence_source", `String evidence_source);
          ("active_task_count", `Int active_task_count);
          ("related_session_id", json_string_option related_session_id);
          ("related_operation_id", json_string_option related_operation_id);
          ("emoji", `String emoji);
          ("korean_name", `String korean_name);
          ("model", `Null);
          ("recent_output_preview", json_string_option recent_output_preview);
          ("recent_event", json_string_option recent_output_preview);
        ];
  }

let continuity_row_of_keeper ~(now_ts : float) ?related_session_id keeper :
    continuity_context =
  let name = string_field "name" keeper in
  let agent_name =
    match trim_to_option (string_field "agent_name" keeper) with
    | Some value -> value
    | None -> name
  in
  let audit = tool_audit_snapshot agent_name in
  let status = string_field ~default:"unknown" "status" keeper in
  let context_ratio =
    match member_assoc "context_ratio" keeper with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | _ -> None
  in
  let last_signal_at =
    match trim_to_option (string_field "last_autonomous_action_at" keeper) with
    | Some value -> Some value
    | None -> trim_to_option (string_field "updated_at" keeper)
  in
  let last_signal_ts = parse_iso_opt last_signal_at |> Option.value ~default:0.0 in
  let last_age_s =
    if last_signal_ts > 0.0 then max 0.0 (now_ts -. last_signal_ts)
    else infinity
  in
  let lifecycle =
    if List.mem status [ "offline"; "inactive"; "error" ] then "offline"
    else if Option.value ~default:0.0 context_ratio >= 0.85 then "handoff-imminent"
    else if Option.value ~default:0.0 context_ratio >= 0.70 then "preparing"
    else if Option.value ~default:0.0 context_ratio >= 0.50 then "compacting"
    else if last_signal_ts > 0.0 then "active"
    else "idle"
  in
  let (state, tone, note) =
    if List.mem status [ "offline"; "inactive"; "error" ] then
      ("critical", "bad", "keeper 오프라인")
    else if lifecycle = "handoff-imminent" then
      ("critical", "bad", "핸드오프 임박")
    else if lifecycle = "preparing" || lifecycle = "compacting" || last_age_s >= 3600.0 then
      ( "warning",
        "warn",
        if last_age_s >= 3600.0 then "최근 자율 활동이 오래 비었습니다"
        else "연속성 압력이 높습니다" )
    else
      ("healthy", "ok", "하트비트와 연속성 상태가 안정적입니다")
  in
  let continuity =
    Printf.sprintf "Gen %d · Turns %d · Goals %d"
      (int_field "generation" keeper)
      (int_field "turn_count" keeper)
      (List.length (list_field "active_goal_ids" keeper))
  in
  let focus =
    match trim_to_option (string_field "short_goal" keeper) with
    | Some value -> value
    | None -> (
        match trim_to_option (string_field "goal" keeper) with
        | Some value -> value
        | None -> "현재 포커스 없음")
  in
  let recent_input_preview =
    trim_to_option (string_field "recent_input_preview" keeper)
  in
  let recent_output_preview =
    trim_to_option (string_field "recent_output_preview" keeper)
    |> option_or_else (fun () -> trim_to_option (string_field "last_proactive_preview" keeper))
  in
  let recent_tool_names =
    let keeper_tools = string_list_of_field "recent_tool_names" keeper in
    if keeper_tools <> [] then keeper_tools else audit.latest_tool_names
  in
  let allowed_tool_names =
    let keeper_tools = string_list_of_field "allowed_tool_names" keeper in
    if keeper_tools <> [] then keeper_tools else audit.allowed_tool_names
  in
  let latest_tool_names =
    let keeper_tools = string_list_of_field "latest_tool_names" keeper in
    if keeper_tools <> [] then keeper_tools else audit.latest_tool_names
  in
  let skill_route_summary = skill_route_summary_of_keeper keeper in
  let (emoji, korean_name) = get_agent_identity name in
  {
    tone_rank = tone_rank tone;
    last_signal_ts;
    related_session_id;
    json =
      `Assoc
        [
          ("name", `String name);
          ("agent_name", member_assoc "agent_name" keeper);
          ("status", `String status);
          ("tone", `String tone);
          ("state", `String state);
          ("note", `String note);
          ("focus", `String focus);
          ("last_signal_at", json_string_option last_signal_at);
          ("last_autonomous_action_at", json_string_option last_signal_at);
          ("generation", member_assoc "generation" keeper);
          ("turn_count", member_assoc "turn_count" keeper);
          ("context_ratio", option_to_json (fun value -> `Float value) context_ratio);
          ("continuity", `String continuity);
          ("lifecycle", `String lifecycle);
          ("related_session_id", json_string_option related_session_id);
          ("recent_input_preview", json_string_option recent_input_preview);
          ("recent_output_preview", json_string_option recent_output_preview);
          ("recent_tool_names", string_list_json recent_tool_names);
          ("allowed_tool_names", string_list_json allowed_tool_names);
          ("latest_tool_names", string_list_json latest_tool_names);
          ("latest_tool_call_count", option_to_json (fun value -> `Int value) audit.latest_tool_call_count);
          ("tool_audit_source", json_string_option audit.tool_audit_source);
          ("tool_audit_at", json_string_option audit.tool_audit_at);
          ("last_proactive_preview", member_assoc "last_proactive_preview" keeper);
          ("continuity_summary", member_assoc "continuity_summary" keeper);
          ("skill_route_summary", json_string_option skill_route_summary);
          ( "model",
            match trim_to_option (string_field "active_model" keeper) with
            | Some value -> `String value
            | None -> `Null );
          ("emoji", `String emoji);
          ("korean_name", `String korean_name);
          ("skill_reason", json_string_option (trim_to_option (string_field "goal" keeper)));
        ];
  }

let session_payload_json session_json =
  match member_assoc "status" session_json with
  | `Assoc _ as payload -> payload
  | _ -> session_json

let session_meta_json session_json =
  session_payload_json session_json |> member_assoc "session"

let session_summary_json session_json =
  session_payload_json session_json |> member_assoc "summary"

let session_team_health_json session_json =
  session_payload_json session_json |> member_assoc "team_health"

let session_communication_json session_json =
  session_payload_json session_json |> member_assoc "communication_metrics"

let session_status_string session_json =
  let summary = session_summary_json session_json in
  let meta = session_meta_json session_json in
  match trim_to_option (string_field "status" summary) with
  | Some value -> value
  | None -> (
      match trim_to_option (string_field "status" meta) with
      | Some value -> value
      | None ->
          trim_to_option (string_field "status" session_json)
          |> Option.value ~default:"unknown")

let session_recent_events session_json =
  list_field "recent_events" session_json

let event_detail_json event_json =
  member_assoc "detail" event_json

let event_summary event_json =
  let detail = event_detail_json event_json in
  let event_type =
    trim_to_option (string_field "event_type" event_json)
    |> Option.value ~default:"event"
  in
  let actor = trim_to_option (string_field "actor" detail) in
  let task_title =
    match trim_to_option (string_field "task_title" detail) with
    | Some value -> Some value
    | None -> trim_to_option (string_field "title" detail)
  in
  let result = trim_to_option (compact_text (string_field "result" detail)) in
  let reason = trim_to_option (compact_text (string_field "reason" detail)) in
  match task_title, result, reason with
  | Some title, _, _ ->
      compact_text
        (Printf.sprintf "%s%s"
           (match actor with Some value -> value ^ " · " | None -> "")
           title)
  | None, Some value, _ -> value
  | None, None, Some value -> value
  | None, None, None -> String.map (fun ch -> if ch = '_' then ' ' else ch) event_type

let session_severity ~health ~status ~runtime_blocker =
  if List.mem health [ "bad"; "critical" ]
     || List.mem status [ "failed"; "cancelled"; "interrupted" ]
  then
    "bad"
  else if List.mem health [ "warn"; "degraded" ]
          || List.mem status [ "paused" ]
          || Option.is_some runtime_blocker
  then
    "warn"
  else
    "ok"

let build_session_seed session_json session_cards =
  let session_id = string_field "session_id" session_json in
  if session_id = "" then None
  else
    let meta = session_meta_json session_json in
    let summary = session_summary_json session_json in
    let team_health = session_team_health_json session_json in
    let communication = session_communication_json session_json in
    let recent_events = session_recent_events session_json in
    let last_event =
      recent_events
      |> List.sort (fun left right ->
             let right_ts =
               parse_iso_opt (trim_to_option (string_field "ts_iso" right))
               |> Option.value ~default:0.0
             in
             let left_ts =
               parse_iso_opt (trim_to_option (string_field "ts_iso" left))
               |> Option.value ~default:0.0
             in
             Float.compare right_ts left_ts)
      |> function
      | item :: _ -> Some item
      | [] -> None
    in
    let session_card =
      List.find_opt
        (fun json -> String.equal (string_field "session_id" json) session_id)
        session_cards
    in
    let top_attention =
      match session_card with
      | Some card -> (
          match member_assoc "top_attention" card with
          | `Null -> None
          | value -> Some value)
      | None -> None
    in
    let top_recommendation =
      match session_card with
      | Some card -> (
          match member_assoc "top_recommendation" card with
          | `Null -> None
          | value -> Some value)
      | None -> None
    in
    let attention_summary =
      Option.bind top_attention (fun json ->
          trim_to_option (string_field "summary" json))
    in
    let attention_kind =
      Option.bind top_attention (fun json -> trim_to_option (string_field "kind" json))
    in
    let runtime_blocker =
      match attention_kind, attention_summary with
      | Some ("spawn_failure_present" | "local64_role_gap" | "stalled_session" | "planned_worker_without_turn"), Some summary ->
          Some summary
      | _ -> attention_summary
    in
    let worker_gap_summary =
      match attention_kind, attention_summary with
      | Some ("spawn_failure_present" | "local64_role_gap" | "planned_worker_without_turn" | "detached_actor_present"), Some summary ->
          Some summary
      | _ -> None
    in
    let mode =
      trim_to_option (string_field "mode" communication)
      |> Option.value ~default:"mode n/a"
    in
    let broadcast_count = int_field "broadcast_count" communication in
    let portal_count = int_field "portal_count" communication in
    let seen_count = int_field "seen_agents_count" summary in
    let member_names =
      dedup_strings
        (string_list_of_json (member_assoc "agent_names" meta)
        @ string_list_of_json (member_assoc "active_agents" summary)
        @ string_list_of_json (member_assoc "planned_participants" summary))
    in
    let planned_count =
      let planned =
        string_list_of_json (member_assoc "planned_participants" summary)
      in
      let explicit = List.length planned in
      if explicit > 0 then explicit else List.length member_names
    in
    let counts_basis =
      if List.length (string_list_of_json (member_assoc "planned_participants" summary)) > 0 then
        "live=recent_turns · planned=planned_participants"
      else
        "live=recent_turns · planned=known_members"
    in
    Some
      {
        session_id;
        goal =
          trim_to_option (string_field "goal" meta)
          |> Option.value ~default:session_id;
        room = trim_to_option (string_field "room_id" meta);
        status = session_status_string session_json;
        health =
          (match session_card with
          | Some card ->
              trim_to_option (string_field "health" card)
              |> Option.value ~default:"ok"
          | None ->
              trim_to_option (string_field "status" team_health)
              |> Option.value ~default:"ok");
        member_names;
        last_activity_at =
          Option.bind last_event (fun json ->
              trim_to_option (string_field "ts_iso" json));
        last_activity_ts =
          Option.bind last_event (fun json ->
              parse_iso_opt (trim_to_option (string_field "ts_iso" json)))
          |> Option.value ~default:0.0;
        last_activity_summary =
          (match last_event with
          | Some value -> event_summary value
          | None -> "최근 session event가 없습니다.");
        communication_summary =
          Printf.sprintf "%s · broadcast %d · portal %d" mode broadcast_count
            portal_count;
        active_count = int_field "active_agents_count" team_health;
        seen_count;
        planned_count;
        required_count = int_field ~default:1 "required_agents" team_health;
        counts_basis;
        runtime_blocker;
        worker_gap_summary;
        top_attention;
        top_recommendation;
      }

let detachment_index command_plane_json =
  let table = Hashtbl.create 32 in
  let detachments =
    member_assoc "detachments" command_plane_json
    |> member_assoc "detachments"
    |> function
    | `List items -> items
    | _ -> []
  in
  List.iter
    (fun detachment_card ->
      let detachment = member_assoc "detachment" detachment_card in
      let operation_id = string_field "operation_id" detachment in
      if operation_id <> "" then
        let session_id =
          trim_to_option (string_field "session_id" detachment)
        in
        let detachment_id =
          trim_to_option (string_field "detachment_id" detachment)
        in
        Hashtbl.replace table operation_id (session_id, detachment_id))
    detachments;
  table

let operation_severity ~status ~blocker_summary =
  if List.mem status [ "failed"; "cancelled" ] then
    "bad"
  else if List.mem status [ "paused" ] || Option.is_some blocker_summary then
    "warn"
  else
    "ok"

let build_operation_contexts command_plane_json =
  let operations =
    member_assoc "operations" command_plane_json
    |> member_assoc "operations"
    |> function
    | `List items -> items
    | _ -> []
  in
  let detachments = detachment_index command_plane_json in
  operations
  |> List.filter_map (fun operation_card ->
         let operation = member_assoc "operation" operation_card in
         let operation_id = string_field "operation_id" operation in
         if operation_id = "" then None
         else
           let search = member_assoc "search" operation_card in
           let blockers = list_field "dependency_blockers" search in
           let blocker_summary =
             match blockers with
             | blocker :: _ ->
                 trim_to_option (string_field "reason" blocker)
             | [] ->
                 if string_field "readiness" search = "blocked" then
                   Some "operation search is blocked"
                 else
                   None
           in
           let status = string_field ~default:"active" "status" operation in
           let severity = operation_severity ~status ~blocker_summary in
           let linked_session_id, linked_detachment_id =
             match Hashtbl.find_opt detachments operation_id with
             | Some (session_id, detachment_id) -> (session_id, detachment_id)
             | None ->
                 ( trim_to_option (string_field "detachment_session_id" operation),
                   None )
           in
           let command_handoff =
             handoff_json
               ~surface:"command"
               ~command_surface:"operations"
               ~operation_id
               ~label:"작전 원인 보기"
               ~target_type:"operation"
               ~target_id:operation_id
               ~focus_kind:"operation"
               ()
           in
           let updated_at =
             trim_to_option (string_field "updated_at" operation)
           in
           Some
             {
               operation_id;
               severity;
               last_seen_ts =
                 parse_iso_opt updated_at |> Option.value ~default:0.0;
               linked_session_id;
               linked_detachment_id;
               json =
                 `Assoc
                   [
                     ("operation_id", `String operation_id);
                     ("objective", member_assoc "objective" operation);
                     ("status", `String status);
                     ("stage", member_assoc "stage" operation);
                     ("assigned_unit_id", member_assoc "assigned_unit_id" operation);
                     ("assigned_unit_label", member_assoc "assigned_unit_label" operation_card);
                     ("linked_session_id", json_string_option linked_session_id);
                     ("linked_detachment_id", json_string_option linked_detachment_id);
                     ("blocker_summary", json_string_option blocker_summary);
                     ("search_status", member_assoc "readiness" search);
                     ( "next_tool",
                       if Option.is_some blocker_summary then `String "masc_operation_status"
                       else `String "masc_observe_operations" );
                     ("updated_at", json_string_option updated_at);
                     ("top_handoff", command_handoff);
                     ("command_handoff", command_handoff);
                   ];
             })
  |> List.sort (fun left right ->
         let by_severity =
           Int.compare
             (severity_rank right.severity)
             (severity_rank left.severity)
         in
         if by_severity <> 0 then by_severity
         else Float.compare right.last_seen_ts left.last_seen_ts)

let session_operation_links operation_contexts =
  let table = Hashtbl.create 32 in
  List.iter
    (fun (operation : operation_context) ->
      match operation.linked_session_id with
      | Some session_id when not (Hashtbl.mem table session_id) ->
          Hashtbl.add table session_id
            (Some operation.operation_id, operation.linked_detachment_id)
      | _ -> ())
    operation_contexts;
  table

let build_session_contexts seeds operation_contexts : session_context list =
  let links = session_operation_links operation_contexts in
  seeds
  |> List.map (fun (seed : session_seed) : session_context ->
         let linked_operation_id, linked_detachment_id =
           match Hashtbl.find_opt links seed.session_id with
           | Some value -> value
           | None -> (None, None)
         in
         let severity =
           session_severity ~health:seed.health ~status:seed.status
             ~runtime_blocker:seed.runtime_blocker
         in
         let intervene_handoff =
           handoff_json
             ~surface:"intervene"
             ~label:"세션 개입 열기"
             ~target_type:"team_session"
             ~target_id:seed.session_id
             ~focus_kind:"team_session"
             ()
         in
         let command_handoff =
           handoff_json
             ~surface:"command"
             ~command_surface:
               (if Option.is_some linked_operation_id then "operations" else "swarm")
             ?operation_id:linked_operation_id
             ~label:"세션 원인 보기"
             ~target_type:"team_session"
             ~target_id:seed.session_id
             ~focus_kind:
               (if Option.is_some linked_operation_id then "operation" else "team_session")
             ()
         in
         let top_handoff =
           match seed.top_recommendation with
           | Some _ -> intervene_handoff
           | None ->
               if severity <> "ok" && Option.is_some linked_operation_id then
                 command_handoff
               else
                 intervene_handoff
         in
         {
           session_id = seed.session_id;
           severity;
           last_seen_ts = seed.last_activity_ts;
           linked_operation_id;
           member_names = seed.member_names;
           json =
             `Assoc
               [
                 ("session_id", `String seed.session_id);
                 ("goal", `String seed.goal);
                 ("room", json_string_option seed.room);
                 ("status", `String seed.status);
                 ("health", `String seed.health);
                 ( "member_names",
                   `List (List.map (fun value -> `String value) seed.member_names) );
                 ("linked_operation_id", json_string_option linked_operation_id);
                 ("linked_detachment_id", json_string_option linked_detachment_id);
                 ("runtime_blocker", json_string_option seed.runtime_blocker);
                 ("worker_gap_summary", json_string_option seed.worker_gap_summary);
                 ("last_activity_at", json_string_option seed.last_activity_at);
                 ("last_activity_summary", `String seed.last_activity_summary);
                 ("communication_summary", `String seed.communication_summary);
                 ("active_count", `Int seed.active_count);
                 ("seen_count", `Int seed.seen_count);
                 ("planned_count", `Int seed.planned_count);
                 ("required_count", `Int seed.required_count);
                 ("counts_basis", `String seed.counts_basis);
                 ("top_handoff", top_handoff);
                 ("intervene_handoff", intervene_handoff);
                 ("command_handoff", command_handoff);
                 ( "top_attention",
                   match seed.top_attention with
                   | Some value -> value
                   | None -> `Null );
                 ( "top_recommendation",
                   match seed.top_recommendation with
                   | Some value -> value
                   | None -> `Null );
               ];
         })
  |> List.sort (fun (left : session_context) (right : session_context) ->
         let by_severity =
           Int.compare
             (severity_rank right.severity)
             (severity_rank left.severity)
         in
         if by_severity <> 0 then by_severity
         else Float.compare right.last_seen_ts left.last_seen_ts)

let queue_summary_of_session (session_context : session_context) =
  match trim_to_option (string_field "runtime_blocker" session_context.json) with
  | Some summary -> summary
  | None -> (
      match trim_to_option (string_field "worker_gap_summary" session_context.json) with
      | Some summary -> summary
      | None ->
          trim_to_option (string_field "last_activity_summary" session_context.json)
          |> Option.value ~default:(string_field "goal" session_context.json))

let build_execution_queue session_contexts operation_contexts =
  let blocked_session_ids =
    session_contexts
    |> List.filter (fun (session : session_context) -> session.severity <> "ok")
    |> List.map (fun (session : session_context) -> session.session_id)
  in
  let session_items =
    session_contexts
    |> List.filter (fun (session : session_context) -> session.severity <> "ok")
    |> List.map (fun (session : session_context) ->
           {
             severity_rank = severity_rank session.severity;
             last_seen_ts = session.last_seen_ts;
             json =
               `Assoc
                 [
                   ("id", `String ("session-" ^ session.session_id));
                   ("kind", `String "session");
                   ("severity", `String session.severity);
                   ("status", member_assoc "status" session.json);
                   ("summary", `String (queue_summary_of_session session));
                   ("target_type", `String "team_session");
                   ("target_id", `String session.session_id);
                   ("linked_session_id", `String session.session_id);
                   ("linked_operation_id", option_to_json (fun value -> `String value) session.linked_operation_id);
                   ("last_seen_at", member_assoc "last_activity_at" session.json);
                   ("top_handoff", member_assoc "top_handoff" session.json);
                   ("intervene_handoff", member_assoc "intervene_handoff" session.json);
                   ("command_handoff", member_assoc "command_handoff" session.json);
                 ];
           })
  in
  let operation_items =
    operation_contexts
    |> List.filter (fun (operation : operation_context) ->
           operation.severity <> "ok"
           &&
           match operation.linked_session_id with
           | Some session_id -> not (List.mem session_id blocked_session_ids)
           | None -> true)
    |> List.map (fun (operation : operation_context) ->
           {
             severity_rank = severity_rank operation.severity;
             last_seen_ts = operation.last_seen_ts;
             json =
               `Assoc
                 [
                   ("id", `String ("operation-" ^ operation.operation_id));
                   ("kind", `String "operation");
                   ("severity", `String operation.severity);
                   ("status", member_assoc "status" operation.json);
                   ( "summary",
                     match trim_to_option (string_field "blocker_summary" operation.json) with
                     | Some summary -> `String summary
                     | None -> member_assoc "objective" operation.json );
                   ("target_type", `String "operation");
                   ("target_id", `String operation.operation_id);
                   ("linked_session_id", json_string_option operation.linked_session_id);
                   ("linked_operation_id", `String operation.operation_id);
                   ("last_seen_at", member_assoc "updated_at" operation.json);
                   ("top_handoff", member_assoc "top_handoff" operation.json);
                   ("intervene_handoff", `Null);
                   ("command_handoff", member_assoc "command_handoff" operation.json);
                 ];
           })
  in
  (session_items @ operation_items)
  |> List.sort (fun left right ->
         let by_severity = Int.compare right.severity_rank left.severity_rank in
         if by_severity <> 0 then by_severity
         else Float.compare right.last_seen_ts left.last_seen_ts)

let related_session_for_member session_contexts name =
  let normalized = String.lowercase_ascii (String.trim name) in
  session_contexts
  |> List.find_opt (fun (session : session_context) ->
         session.member_names
         |> List.exists (fun member ->
                String.equal
                  (String.lowercase_ascii (String.trim member))
                  normalized))

let build_worker_support_briefs ~(now_ts : float) ~(tasks : Types.task list)
    ~(agents : Types.agent list) ~(messages : Types.message list) session_contexts :
    worker_context list =
  let messages_by_agent = last_message_map messages in
  agents
  |> List.map (fun (agent : Types.agent) ->
         let related =
           related_session_for_member session_contexts agent.name
         in
         let related_session_id =
           match related with
           | Some session -> Some session.session_id
           | None -> None
         in
         let related_operation_id =
           match related with
           | Some session -> session.linked_operation_id
           | None -> None
         in
         worker_state_of_agent ~now_ts ~messages_by_agent ~tasks ?related_session_id
           ?related_operation_id agent)
  |> List.filter (fun (row : worker_context) ->
         row.related_session_id <> None || string_field "tone" row.json <> "ok")
  |> List.sort (fun (left : worker_context) (right : worker_context) ->
         let by_tone = Int.compare right.tone_rank left.tone_rank in
         if by_tone <> 0 then by_tone
         else Float.compare right.last_signal_ts left.last_signal_ts)

let build_continuity_briefs ~(now_ts : float) keepers session_contexts :
    continuity_context list =
  keepers
  |> List.filter_map (fun keeper ->
         let name = string_field "name" keeper in
         if name = "" then None
         else
           let related_session =
             related_session_for_member session_contexts name
           in
           let related_session_id =
             match related_session with
             | Some session -> Some session.session_id
             | None -> (
                 match trim_to_option (string_field "agent_name" keeper) with
                 | Some agent_name -> (
                     match related_session_for_member session_contexts agent_name with
                     | Some session -> Some session.session_id
                     | None -> None)
                 | None -> None)
           in
           let row =
             continuity_row_of_keeper ~now_ts ?related_session_id keeper
           in
           if string_field "tone" row.json <> "ok" || row.related_session_id <> None then
             Some row
           else
             None)
  |> List.sort (fun (left : continuity_context) (right : continuity_context) ->
         let by_tone = Int.compare right.tone_rank left.tone_rank in
         if by_tone <> 0 then by_tone
         else Float.compare right.last_signal_ts left.last_signal_ts)

let json ?actor ?fixture ~config ~sw ~clock ~proc_mgr () =
  let effective_actor = Option.value ~default:"dashboard" actor in
  match dashboard_fixture_name ?fixture () with
  | Some "execution_smoke" -> execution_smoke_fixture_json ()
  | _ ->
      let tasks = tasks_safe config in
      let agents = agents_safe config in
      let messages = messages_safe config in
      let ctx : _ Operator_control.context =
        {
          config;
          agent_name = effective_actor;
          sw;
          clock;
          proc_mgr;
          mcp_session_id = None;
        }
      in
      (* Yield between heavy phases so SSE / health-check fibers can progress *)
      Eio.Fiber.yield ();
      (* Load sessions once; pass to snapshot_json to avoid repeated filesystem scans *)
      let sessions =
        if Room.is_initialized config then
          Team_session_store.list_sessions config
        else []
      in
      Eio.Fiber.yield ();
      let snapshot_json =
        Dashboard_cache.get_or_compute
          (Printf.sprintf "snapshot:%s" effective_actor)
          ~ttl:3.0
          (fun () ->
            Operator_control.snapshot_json
              ~actor:effective_actor
              ~view:"summary"
              ~include_messages:false
              ~include_sessions:true
              ~include_keepers:true
              ~sessions
              ctx)
      in
      Eio.Fiber.yield ();
      let digest_json =
        Dashboard_cache.get_or_compute
          (Printf.sprintf "digest:%s" effective_actor)
          ~ttl:5.0
          (fun () ->
            match Operator_control.digest_json ~actor:effective_actor ctx with
            | Ok json -> json
            | Error message ->
                `Assoc
                  [
                    ("health", `String "warn");
                    ("attention_items", `List []);
                    ("recommended_actions", `List []);
                    ("session_cards", `List []);
                    ("error", `String message);
                  ])
      in
      let session_cards = list_field "session_cards" digest_json in
      let session_seeds =
        member_assoc "sessions" snapshot_json |> member_assoc "items"
        |> function
        | `List items ->
            items
            |> List.filter_map (fun json -> build_session_seed json session_cards)
        | _ -> []
      in
      (* Yield between heavy computation phases to prevent fiber starvation.
         Eio's cooperative scheduler needs explicit yields in CPU-bound paths
         so other fibers (SSE, health checks) can progress. *)
      Eio.Fiber.yield ();
      let command_plane_json = member_assoc "command_plane" snapshot_json in
      let operation_contexts = build_operation_contexts command_plane_json in
      let session_contexts =
        build_session_contexts session_seeds operation_contexts
      in
      let execution_queue =
        build_execution_queue session_contexts operation_contexts
      in
      let keepers =
        member_assoc "keepers" snapshot_json |> member_assoc "items"
        |> function
        | `List items -> items
        | _ -> []
      in
      Eio.Fiber.yield ();
      let now_ts = Time_compat.now () in
      let worker_rows =
        build_worker_support_briefs ~now_ts ~tasks ~agents ~messages session_contexts
      in
      let offline_worker_briefs, worker_support_briefs =
        List.partition
          (fun (row : worker_context) ->
             string_field "state" row.json = "offline")
          worker_rows
      in
      let continuity_rows =
        build_continuity_briefs ~now_ts keepers session_contexts
      in
      let social_tick_json, social_checkins =
        Social_runtime.execution_json ~config
      in
      let social_tick_summary =
        social_tick_json |> member_assoc "summary"
      in
      `Assoc
        [
          ("generated_at", `String (Types.now_iso ()));
          ("status", room_status_json config);
          ("social_tick", social_tick_summary);
          ("social_checkins", `List social_checkins);
          ("lodge_tick", social_tick_summary);
          ("lodge_checkins", `List social_checkins);
          ("execution_queue", `List (List.map (fun (row : queue_context) -> row.json) execution_queue));
          ("priority_queue", `List (List.map (fun (row : queue_context) -> row.json) execution_queue));
          ("session_briefs", `List (List.map (fun (row : session_context) -> row.json) session_contexts));
          ("operation_briefs", `List (List.map (fun (row : operation_context) -> row.json) operation_contexts));
          ("worker_support_briefs", `List (List.map (fun (row : worker_context) -> row.json) worker_support_briefs));
          ("worker_briefs", `List (List.map (fun (row : worker_context) -> row.json) worker_support_briefs));
          ("continuity_briefs", `List (List.map (fun (row : continuity_context) -> row.json) continuity_rows));
          ("offline_worker_briefs", `List (List.map (fun (row : worker_context) -> row.json) offline_worker_briefs));
          ("agents", `List (List.map agent_json agents));
          ("tasks", `List (List.map task_json tasks));
          ("messages", `List (List.map message_json messages));
          ("keepers", `List keepers);
        ]
