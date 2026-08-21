open Masc

let test_decode_agent_success () =
  let json =
    `Assoc [
      ("name", `String "alice");
      ("status", `String "live");
      ("current_task", `String "task-1");
      ("last_seen", `String "2026-03-31T12:00:00Z");
    ]
  in
  match Tui_decode.decode_agent json with
  | Ok agent ->
      Alcotest.(check string) "name" "alice" agent.name;
      Alcotest.(check string) "status" "live" agent.status;
      Alcotest.(check (option string)) "task" (Some "task-1") agent.current_task
  | Error err -> Alcotest.fail err

let test_decode_agent_missing_status_fails () =
  let json =
    `Assoc [
      ("name", `String "alice");
      ("last_seen", `String "2026-03-31T12:00:00Z");
    ]
  in
  Alcotest.(check bool) "missing status rejected" true
    (Result.is_error (Tui_decode.decode_agent json))

let test_decode_task_missing_priority_defaults () =
  let json =
    `Assoc [
      ("id", `String "task-1");
      ("title", `String "Tighten parser");
      ("status", `String "todo");
    ]
  in
  match Tui_decode.decode_task json with
  | Ok task ->
      Alcotest.(check int) "default priority" 3 task.priority;
      Alcotest.(check string) "typed status" "todo"
        (Masc_domain.task_status_to_string task.status)
  | Error err -> Alcotest.fail err

let domain_task ~id ~priority status_fields =
  let json =
    `Assoc
      ([ "id", `String id
       ; "title", `String ("Task " ^ id)
       ; "priority", `Int priority
       ; "created_at", `String "2026-08-21T00:00:00Z"
       ]
      @ status_fields)
  in
  match Masc_domain.task_of_yojson json with
  | Ok task -> task
  | Error err -> Alcotest.fail err

let test_active_tasks_of_domain_filters_and_sorts () =
  let tasks =
    [ domain_task ~id:"done" ~priority:0
        [ "status", `String "done"
        ; "assignee", `String "alice"
        ; "completed_at", `String "2026-08-21T00:00:00Z"
        ]
    ; domain_task ~id:"todo" ~priority:3 [ "status", `String "todo" ]
    ; domain_task ~id:"running" ~priority:1
        [ "status", `String "in_progress"
        ; "assignee", `String "bob"
        ; "started_at", `String "2026-08-21T00:00:00Z"
        ]
    ; domain_task ~id:"cancelled" ~priority:2
        [ "status", `String "cancelled"
        ; "cancelled_by", `String "operator"
        ; "cancelled_at", `String "2026-08-21T00:00:00Z"
        ]
    ]
  in
  let active = Tui_decode.active_tasks_of_domain tasks in
  Alcotest.(check (list string)) "terminal tasks removed, priority preserved"
    [ "running"; "todo" ]
    (List.map (fun (task : Tui_decode.task) -> task.id) active)

let current_keeper_json ?(last_turn_ts = 0.0) ?(paused = false)
    ?(current_task_id = None) () =
  let optional_field key = function
    | Some value -> [ (key, value) ]
    | None -> []
  in
  let fixture =
    `Assoc
      ([ ("name", `String "keeper-main")
       ; ("generation", `Int 2)
       ; ("paused", `Bool paused)
       ; ("total_turns", `Int 4)
       ; ("total_tokens", `Int 120)
       ; ("total_cost_usd", `Float 0.42)
       ; ("last_turn_ts", `Float last_turn_ts)
       ; ("compaction_count", `Int 1)
       ; ("autonomous_turn_count", `Int 7)
       ; ("autonomous_text_turn_count", `Int 5)
       ; ("autonomous_tool_turn_count", `Int 2)
       ; ("board_reactive_turn_count", `Int 3)
       ; ("mention_reactive_turn_count", `Int 1)
       ; ("noop_turn_count", `Int 4)
       ; ("last_proactive_outcome", `String "tool_use")
       ; ( "last_blocker"
         , Keeper_meta_contract.(
             blocker_info_of_class ~detail:"queue full" Capacity_backpressure
             |> blocker_info_to_json) )
       ; ("created_at", `String "2026-08-20T01:02:03Z")
       ; ("updated_at", `String "2026-08-21T04:05:06Z")
       ]
      @ optional_field "current_task_id"
          (Option.map (fun id -> `String id) current_task_id))
  in
  match Masc_test_deps.meta_of_json_fixture fixture with
  | Ok meta -> Keeper_meta_json.meta_to_json meta
  | Error err -> Alcotest.fail err

let test_decode_keeper_projects_current_schema () =
  match
    Tui_decode.decode_keeper
      (current_keeper_json ~paused:true ~current_task_id:(Some "task-42") ())
  with
  | Ok keeper ->
      Alcotest.(check string) "name" "keeper-main" keeper.k_name;
      Alcotest.(check int) "generation" 2 keeper.k_generation;
      Alcotest.(check bool) "paused" true keeper.k_paused;
      Alcotest.(check (option string)) "current task" (Some "task-42")
        keeper.k_current_task_id;
      Alcotest.(check int) "autonomous turns" 7
        keeper.k_autonomous_turn_count;
      Alcotest.(check int) "total turns" 4 keeper.k_total_turns;
      Alcotest.(check int) "total tokens" 120 keeper.k_total_tokens;
      Alcotest.(check (float 0.0001)) "total cost" 0.42
        keeper.k_total_cost_usd;
      Alcotest.(check int) "compactions" 1 keeper.k_compaction_count;
      Alcotest.(check int) "autonomous text turns" 5
        keeper.k_autonomous_text_turn_count;
      Alcotest.(check int) "autonomous tool turns" 2
        keeper.k_autonomous_tool_turn_count;
      Alcotest.(check int) "board turns" 3
        keeper.k_board_reactive_turn_count;
      Alcotest.(check int) "mention turns" 1
        keeper.k_mention_reactive_turn_count;
      Alcotest.(check int) "no-op turns" 4 keeper.k_noop_turn_count;
      Alcotest.(check string) "last outcome" "tool_use"
        keeper.k_last_proactive_outcome;
      Alcotest.(check (option string)) "last blocker"
        (Some "capacity_backpressure: queue full")
        keeper.k_last_blocker;
      Alcotest.(check string) "created at" "2026-08-20T01:02:03Z"
        keeper.k_created_at;
      Alcotest.(check string) "updated at" "2026-08-21T04:05:06Z"
        keeper.k_updated_at
  | Error err -> Alcotest.fail err

let test_decode_keeper_formats_last_turn_timestamp () =
  let timestamp = 1700000000.9 in
  match
    Tui_decode.decode_keeper (current_keeper_json ~last_turn_ts:timestamp ())
  with
  | Ok keeper ->
      Alcotest.(check string) "timestamp uses canonical ISO formatter"
        (Masc_domain.iso8601_of_unix_seconds timestamp)
        keeper.k_last_turn_ts
  | Error err -> Alcotest.fail err

let test_decode_keeper_zero_last_turn_is_empty () =
  match Tui_decode.decode_keeper (current_keeper_json ()) with
  | Ok keeper ->
      Alcotest.(check string) "zero timestamp becomes empty" ""
        keeper.k_last_turn_ts
  | Error err -> Alcotest.fail err

let test_decode_keeper_rejects_retired_fields () =
  List.iter
    (fun field ->
      let json =
        match current_keeper_json () with
        | `Assoc fields -> `Assoc ((field, `Bool true) :: fields)
        | _ -> Alcotest.fail "current keeper fixture must be an object"
      in
      Alcotest.(check bool) ("retired field rejected: " ^ field) true
        (Result.is_error (Tui_decode.decode_keeper json)))
    [ "active_goal_ids"
    ; "active_model"
    ; "models"
    ; "proactive_enabled"
    ; "initiative_enabled"
    ; "trigger_mode"
    ; "context_budget"
    ; "drift_enabled"
    ; "verify"
    ]

let test_dotted_keeper_metadata_name_is_preserved () =
  Alcotest.(check (option string)) "portable dotted Keeper name"
    (Some "alpha.with.dot")
    (Keeper_runtime_root_entry.metadata_keeper_name "alpha.with.dot.json")

let test_decode_keeper_rejects_missing_current_field () =
  let json =
    match current_keeper_json () with
    | `Assoc fields ->
        `Assoc (List.filter (fun (key, _) -> key <> "paused") fields)
    | _ -> Alcotest.fail "current keeper fixture must be an object"
  in
  Alcotest.(check bool) "missing current field rejected" true
    (Result.is_error (Tui_decode.decode_keeper json))

let planning_goal_json id phase priority =
  `Assoc
    [ "id", `String id
    ; "title", `String ("Goal " ^ id)
    ; "phase", `String phase
    ; "priority", `Int priority
    ]

let planning_snapshot_json ?(running_key = "in_progress") () =
  `Assoc
    [ ( "goals"
      , `List
          (List.mapi
             (fun index phase ->
                planning_goal_json (Printf.sprintf "goal-%d" index) phase index)
             [ "executing"
             ; "blocked"
             ; "paused"
             ; "verifying"
             ; "completed"
             ; "dropped"
             ]) )
    ; ( "rollup"
      , `Assoc
          [ "active_count", `Int 1
          ; "paused_count", `Int 2
          ; "verifying_count", `Int 3
          ; "done_count", `Int 4
          ; "dropped_count", `Int 5
          ] )
    ; ( "task_backlog"
      , `Assoc
          [ "todo", `Int 6
          ; "claimed", `Int 7
          ; running_key, `Int 8
          ; "done", `Int 9
          ; "cancelled", `Int 10
          ] )
    ; "generated_at", `String "2026-08-21T05:06:07Z"
    ]

let test_decode_planning_snapshot_current_contract () =
  match Tui_decode.decode_planning_snapshot (planning_snapshot_json ()) with
  | Error err -> Alcotest.fail err
  | Ok snapshot ->
      Alcotest.(check (list string)) "all canonical phases"
        [ "executing"; "blocked"; "paused"; "verifying"; "completed"; "dropped" ]
        (List.map
           (fun (goal : Tui_decode.planning_goal) ->
              Goal_phase.to_string goal.pg_phase)
           snapshot.pl_goals);
      Alcotest.(check int) "active" 1 snapshot.pl_rollup.pr_active;
      Alcotest.(check int) "paused and blocked" 2 snapshot.pl_rollup.pr_paused;
      Alcotest.(check int) "verifying" 3 snapshot.pl_rollup.pr_verifying;
      Alcotest.(check int) "done" 4 snapshot.pl_rollup.pr_done;
      Alcotest.(check int) "dropped" 5 snapshot.pl_rollup.pr_dropped;
      Alcotest.(check int) "todo" 6 snapshot.pl_backlog.pb_todo;
      Alcotest.(check int) "claimed" 7 snapshot.pl_backlog.pb_claimed;
      Alcotest.(check int) "in progress" 8 snapshot.pl_backlog.pb_running;
      Alcotest.(check int) "backlog done" 9 snapshot.pl_backlog.pb_done;
      Alcotest.(check int) "cancelled" 10 snapshot.pl_backlog.pb_cancelled;
      Alcotest.(check string) "generated at" "2026-08-21T05:06:07Z"
        snapshot.pl_generated_at

let test_decode_planning_snapshot_rejects_running_alias () =
  Alcotest.(check bool) "retired running alias rejected" true
    (Result.is_error
       (Tui_decode.decode_planning_snapshot
          (planning_snapshot_json ~running_key:"running" ())))

let test_parse_log_entry_success () =
  let line =
    Yojson.Safe.to_string
      (`Assoc [
         ("ts", `String "2026-03-31T12:00:00Z");
         ("channel", `String "hb");
         ("context_ratio", `Float 0.55);
         ("context_tokens", `Int 100);
         ("context_max", `Int 200);
         ("message_count", `Int 4);
         ("usage", `Assoc [("input_tokens", `Int 10); ("output_tokens", `Int 12)]);
         ("work_kind", `String "heartbeat");
       ])
  in
  match Tui_decode.parse_log_entry line with
  | Ok entry ->
      Alcotest.(check (option int)) "input tokens" (Some 10) entry.le_input_tokens;
      Alcotest.(check (option string)) "work kind" (Some "heartbeat") entry.le_work_kind
  | Error err -> Alcotest.fail err

let test_parse_log_entry_missing_required_field_fails () =
  let line =
    Yojson.Safe.to_string
      (`Assoc [
         ("ts", `String "2026-03-31T12:00:00Z");
         ("channel", `String "hb");
         ("context_ratio", `Float 0.55);
         ("context_max", `Int 200);
         ("message_count", `Int 4);
       ])
  in
  Alcotest.(check bool) "missing context_tokens rejected" true
    (Result.is_error (Tui_decode.parse_log_entry line))

let test_parse_log_entry_partial_usage_is_allowed () =
  let line =
    Yojson.Safe.to_string
      (`Assoc [
         ("ts", `String "2026-03-31T12:00:00Z");
         ("channel", `String "hb");
         ("context_ratio", `Float 0.55);
         ("context_tokens", `Int 100);
         ("context_max", `Int 200);
         ("message_count", `Int 4);
         ("usage", `Assoc [("input_tokens", `Int 10)]);
       ])
  in
  match Tui_decode.parse_log_entry line with
  | Ok entry ->
      Alcotest.(check (option int)) "input tokens" (Some 10) entry.le_input_tokens;
      Alcotest.(check (option int)) "missing output tokens" None entry.le_output_tokens
  | Error err -> Alcotest.fail err

let test_parse_log_entry_missing_usage_is_allowed () =
  let line =
    Yojson.Safe.to_string
      (`Assoc [
         ("ts", `String "2026-03-31T12:00:00Z");
         ("channel", `String "hb");
         ("context_ratio", `Float 0.55);
         ("context_tokens", `Int 100);
         ("context_max", `Int 200);
         ("message_count", `Int 4);
       ])
  in
  match Tui_decode.parse_log_entry line with
  | Ok entry ->
      Alcotest.(check (option int)) "missing input tokens" None entry.le_input_tokens;
      Alcotest.(check (option int)) "missing output tokens" None entry.le_output_tokens
  | Error err -> Alcotest.fail err

let test_parse_keeper_chat_response_sse_delta () =
  let response =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n\
     data: {\"type\":\"content_delta\",\"delta\":\"hello\"}\n\
     data: {\"type\":\"delta\",\"delta\":\" world\"}\n"
  in
  match Tui_decode.parse_keeper_chat_response response with
  | Ok text -> Alcotest.(check string) "delta text" "hello world" text
  | Error err -> Alcotest.fail err

let test_parse_keeper_chat_response_ag_ui_sse () =
  let response =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n\
     data: {\"type\":\"RUN_STARTED\",\"threadId\":\"default\",\"runId\":\"run-1\"}\n\n\
     data: {\"type\":\"TEXT_MESSAGE_CONTENT\",\"threadId\":\"default\",\"runId\":\"run-1\",\"delta\":\"hello\"}\n\n\
     data: {\"type\":\"TEXT_MESSAGE_CONTENT\",\"threadId\":\"default\",\"runId\":\"run-1\",\"delta\":\" world\"}\n\n\
     data: {\"type\":\"RUN_FINISHED\",\"threadId\":\"default\",\"runId\":\"run-1\"}\n\n"
  in
  match Tui_decode.parse_keeper_chat_response response with
  | Ok text -> Alcotest.(check string) "AG-UI delta text" "hello world" text
  | Error err -> Alcotest.fail err

let test_parse_keeper_chat_response_ag_ui_error () =
  let response =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n\
     data: {\"type\":\"RUN_ERROR\",\"threadId\":\"default\",\"runId\":\"run-1\",\"message\":\"boom\"}\n\n"
  in
  match Tui_decode.parse_keeper_chat_response response with
  | Ok text -> Alcotest.failf "expected RUN_ERROR failure, got %S" text
  | Error err -> Alcotest.(check string) "AG-UI error message" "boom" err

let test_parse_keeper_chat_response_ag_ui_empty_terminal () =
  let response =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n\
     data: {\"type\":\"RUN_FINISHED\",\"threadId\":\"default\",\"runId\":\"run-1\"}\n\n"
  in
  match Tui_decode.parse_keeper_chat_response response with
  | Ok text -> Alcotest.(check string) "empty terminal response" "" text
  | Error err -> Alcotest.fail err

let test_parse_keeper_chat_response_body_json () =
  let response = "{\"result\":{\"text\":\"hello body\"}}" in
  match Tui_decode.parse_keeper_chat_response response with
  | Ok text -> Alcotest.(check string) "body text" "hello body" text
  | Error err -> Alcotest.fail err

let test_parse_keeper_chat_response_json_error () =
  let response =
    "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n\r\n\
     {\"error\":{\"message\":\"boom\"}}"
  in
  match Tui_decode.parse_keeper_chat_response response with
  | Ok _ -> Alcotest.fail "expected parse failure"
  | Error err -> Alcotest.(check string) "error message" "boom" err

let test_decode_json_response_body_rejects_error_status () =
  match
    Tui_decode.decode_json_response_body ~allow_empty:true ~status_code:400
      ~body:"{\"error\":\"bad confirm\"}"
  with
  | Ok _ -> Alcotest.fail "expected HTTP 400 to fail"
  | Error err ->
      Alcotest.(check string)
        "http error" "HTTP 400: {\"error\":\"bad confirm\"}" err

let test_decode_json_response_body_allows_empty_success () =
  match
    Tui_decode.decode_json_response_body ~allow_empty:true ~status_code:204
      ~body:""
  with
  | Ok (`Assoc []) -> ()
  | Ok json ->
      Alcotest.failf "expected empty object, got %s" (Yojson.Safe.to_string json)
  | Error err -> Alcotest.fail err

type parent_node = {
  node_id : string;
  parent_id : string option;
}

let test_bounded_parent_depth_stops_on_cycle () =
  let a = { node_id = "a"; parent_id = Some "b" } in
  let b = { node_id = "b"; parent_id = Some "a" } in
  let depth =
    Tui_decode.bounded_parent_depth
      ~id_of:(fun n -> n.node_id)
      ~parent_id_of:(fun n -> n.parent_id)
      [ a; b ] a
  in
  Alcotest.(check int) "cycle stops at first repeated parent" 1 depth

let () =
  Alcotest.run "tui_decode" [
    ( "decode_agent",
      [
        Alcotest.test_case "success" `Quick test_decode_agent_success;
        Alcotest.test_case "missing status fails" `Quick
          test_decode_agent_missing_status_fails;
      ] );
    ( "decode_task",
      [
        Alcotest.test_case "missing priority defaults" `Quick
          test_decode_task_missing_priority_defaults;
        Alcotest.test_case "active projection filters and sorts" `Quick
          test_active_tasks_of_domain_filters_and_sorts;
      ] );
    ( "decode_keeper",
      [
        Alcotest.test_case "projects current schema" `Quick
          test_decode_keeper_projects_current_schema;
        Alcotest.test_case "formats last turn timestamp" `Quick
          test_decode_keeper_formats_last_turn_timestamp;
        Alcotest.test_case "zero last turn is empty" `Quick
          test_decode_keeper_zero_last_turn_is_empty;
        Alcotest.test_case "rejects retired fields" `Quick
          test_decode_keeper_rejects_retired_fields;
        Alcotest.test_case "preserves dotted metadata name" `Quick
          test_dotted_keeper_metadata_name_is_preserved;
        Alcotest.test_case "rejects missing current field" `Quick
          test_decode_keeper_rejects_missing_current_field;
      ] );
    ( "decode_planning",
      [
        Alcotest.test_case "current contract" `Quick
          test_decode_planning_snapshot_current_contract;
        Alcotest.test_case "rejects running alias" `Quick
          test_decode_planning_snapshot_rejects_running_alias;
      ] );
    ( "parse_log_entry",
      [
        Alcotest.test_case "success" `Quick test_parse_log_entry_success;
        Alcotest.test_case "missing required field fails" `Quick
          test_parse_log_entry_missing_required_field_fails;
        Alcotest.test_case "partial usage is allowed" `Quick
          test_parse_log_entry_partial_usage_is_allowed;
        Alcotest.test_case "missing usage is allowed" `Quick
          test_parse_log_entry_missing_usage_is_allowed;
      ] );
    ( "parse_keeper_chat_response",
      [
        Alcotest.test_case "sse delta" `Quick
          test_parse_keeper_chat_response_sse_delta;
        Alcotest.test_case "AG-UI SSE" `Quick
          test_parse_keeper_chat_response_ag_ui_sse;
        Alcotest.test_case "AG-UI error" `Quick
          test_parse_keeper_chat_response_ag_ui_error;
        Alcotest.test_case "AG-UI empty terminal" `Quick
          test_parse_keeper_chat_response_ag_ui_empty_terminal;
        Alcotest.test_case "body json" `Quick
          test_parse_keeper_chat_response_body_json;
        Alcotest.test_case "json error" `Quick
          test_parse_keeper_chat_response_json_error;
      ] );
    ( "structured_http_response",
      [
        Alcotest.test_case "body rejects error status" `Quick
          test_decode_json_response_body_rejects_error_status;
        Alcotest.test_case "body allows empty success" `Quick
          test_decode_json_response_body_allows_empty_success;
      ] );
    ( "bounded_parent_depth",
      [
        Alcotest.test_case "stops on cycle" `Quick
          test_bounded_parent_depth_stops_on_cycle;
      ] );
  ]
