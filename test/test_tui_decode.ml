open Masc_mcp

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
  | Ok task -> Alcotest.(check int) "default priority" 3 task.priority
  | Error err -> Alcotest.fail err

let keeper_json ?(models = `List [ `String "glm-5.1" ]) ?(last_turn_ts = `String "1700000000")
    ?(active_model = Some (`String "glm-5.1"))
    ?(initiative_enabled = Some (`Bool true)) () =
  let optional_field key = function
    | Some value -> [ (key, value) ]
    | None -> []
  in
  `Assoc
    ([
       ("goal", `String "keep the system healthy");
       ("short_goal", `String "stay responsive");
       ("soul_profile", `String "balanced");
       ("generation", `Int 2);
       ("models", models);
       ("proactive_enabled", `Bool true);
       ("total_turns", `Int 4);
       ("total_tokens", `Int 120);
       ("total_cost_usd", `Float 0.42);
       ("last_turn_ts", last_turn_ts);
       ("compaction_count", `Int 1);
       ("compaction_ratio_gate", `Float 0.8);
       ("room_scope", `String "masc");
       ("trigger_mode", `String "mention");
       ("context_budget", `Int 32000);
       ("handoff_threshold", `Float 0.85);
       ("drift_enabled", `Bool true);
       ("verify", `Bool true);
       ("created_at", `String "2026-03-31T12:00:00Z");
       ("updated_at", `String "2026-03-31T12:05:00Z");
     ]
    @ optional_field "active_model" active_model
    @ optional_field "initiative_enabled" initiative_enabled)

let test_decode_keeper_missing_legacy_fields_defaults_to_none () =
  match
    Tui_decode.decode_keeper ~filename:"keeper-main.json"
      (keeper_json ~active_model:None ~initiative_enabled:None ())
  with
  | Ok keeper ->
      Alcotest.(check string) "filename fallback" "keeper-main" keeper.k_name;
      Alcotest.(check (option string)) "missing active_model" None
        keeper.k_active_model;
      Alcotest.(check (option bool)) "missing initiative_enabled" None
        keeper.k_initiative_enabled
  | Error err -> Alcotest.fail err

let test_decode_keeper_numeric_last_turn_ts_truncates () =
  match
    Tui_decode.decode_keeper ~filename:"keeper-main.json"
      (keeper_json ~last_turn_ts:(`Float 1700000000.9) ())
  with
  | Ok keeper ->
      Alcotest.(check string) "float timestamp truncates" "1700000000"
        keeper.k_last_turn_ts
  | Error err -> Alcotest.fail err

let test_decode_keeper_null_last_turn_ts_is_empty () =
  match
    Tui_decode.decode_keeper ~filename:"keeper-main.json"
      (keeper_json ~last_turn_ts:`Null ())
  with
  | Ok keeper ->
      Alcotest.(check string) "null timestamp becomes empty" "" keeper.k_last_turn_ts
  | Error err -> Alcotest.fail err

let test_decode_keeper_rejects_invalid_models_type () =
  Alcotest.(check bool) "invalid models rejected" true
    (Result.is_error
       (Tui_decode.decode_keeper ~filename:"keeper-main.json"
          (keeper_json ~models:(`String "glm-5.1") ())))

let test_decode_keeper_rejects_non_string_model_items () =
  Alcotest.(check bool) "non-string model entries rejected" true
    (Result.is_error
       (Tui_decode.decode_keeper ~filename:"keeper-main.json"
          (keeper_json ~models:(`List [ `String "glm-5.1"; `Int 7 ]) ())))

let test_decode_keeper_rejects_non_finite_last_turn_ts () =
  Alcotest.(check bool) "non-finite timestamp rejected" true
    (Result.is_error
       (Tui_decode.decode_keeper ~filename:"keeper-main.json"
          (keeper_json ~last_turn_ts:(`Float Float.infinity) ())))

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
         ("guardrail_stop", `Bool false);
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

let test_parse_keeper_chat_response_json_error () =
  let response =
    "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n\r\n\
     {\"error\":{\"message\":\"boom\"}}"
  in
  match Tui_decode.parse_keeper_chat_response response with
  | Ok _ -> Alcotest.fail "expected parse failure"
  | Error err -> Alcotest.(check string) "error message" "boom" err

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
      ] );
    ( "decode_keeper",
      [
        Alcotest.test_case "missing legacy fields default to none" `Quick
          test_decode_keeper_missing_legacy_fields_defaults_to_none;
        Alcotest.test_case "numeric last_turn_ts truncates" `Quick
          test_decode_keeper_numeric_last_turn_ts_truncates;
        Alcotest.test_case "null last_turn_ts is empty" `Quick
          test_decode_keeper_null_last_turn_ts_is_empty;
        Alcotest.test_case "rejects invalid models type" `Quick
          test_decode_keeper_rejects_invalid_models_type;
        Alcotest.test_case "rejects non-string model items" `Quick
          test_decode_keeper_rejects_non_string_model_items;
        Alcotest.test_case "rejects non-finite last_turn_ts" `Quick
          test_decode_keeper_rejects_non_finite_last_turn_ts;
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
        Alcotest.test_case "json error" `Quick
          test_parse_keeper_chat_response_json_error;
      ] );
  ]
