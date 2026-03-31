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

let test_parse_requested_action_uses_typed_decoder () =
  let args =
    `Assoc [
      ( "requested_action",
        `Assoc [
          ("action_type", `String "restart_keeper");
          ("target_id", `String "keeper-main");
          ("payload", `Assoc [("reason", `String "refresh")]);
        ] );
    ]
  in
  match Tool_council_helpers.parse_requested_action args with
  | Ok (Some request) ->
      Alcotest.(check string) "action type" "restart_keeper" request.action_type;
      Alcotest.(check (option string)) "target" (Some "keeper-main")
        request.target_id
  | Ok None -> Alcotest.fail "expected requested_action"
  | Error err -> Alcotest.fail err

let test_parse_requested_action_rejects_unknown_type () =
  let args =
    `Assoc [
      ("requested_action", `Assoc [("action_type", `String "drop_database")]);
    ]
  in
  Alcotest.(check bool) "unknown action rejected" true
    (Result.is_error (Tool_council_helpers.parse_requested_action args))

let () =
  Alcotest.run "tui_decode" [
    ( "decode_agent",
      [
        Alcotest.test_case "success" `Quick test_decode_agent_success;
        Alcotest.test_case "missing status fails" `Quick
          test_decode_agent_missing_status_fails;
      ] );
    ( "parse_log_entry",
      [
        Alcotest.test_case "success" `Quick test_parse_log_entry_success;
        Alcotest.test_case "missing required field fails" `Quick
          test_parse_log_entry_missing_required_field_fails;
      ] );
    ( "parse_keeper_chat_response",
      [
        Alcotest.test_case "sse delta" `Quick
          test_parse_keeper_chat_response_sse_delta;
        Alcotest.test_case "json error" `Quick
          test_parse_keeper_chat_response_json_error;
      ] );
    ( "parse_requested_action",
      [
        Alcotest.test_case "success" `Quick
          test_parse_requested_action_uses_typed_decoder;
        Alcotest.test_case "rejects unknown type" `Quick
          test_parse_requested_action_rejects_unknown_type;
      ] );
  ]
