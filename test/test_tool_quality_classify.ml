(** Unit tests for Dashboard_http_tool_quality.classify_failure_output.

    Verifies that error category classification correctly strips known
    prefixes and extracts the actual error key from JSON output. *)

open Alcotest

let classify = Masc_mcp.Dashboard_http_tool_quality.classify_failure_output

let test_bare_json_error () =
  let output = {|{"ok":false,"error":"Invalid task state"}|} in
  check string "bare JSON extracts error key"
    "Invalid task state" (classify output)

let test_error_prefix_stripped () =
  let output = {|error: {"ok":false,"error":"❌ Invalid task state: Cannot start"}|} in
  check string "error: prefix stripped, key extracted"
    "\xe2\x9d\x8c Invalid task state: Cannot start" (classify output)

let test_tool_error_prefix_stripped () =
  let output = {|tool_error: {"ok":false,"error":"command_blocked"}|} in
  check string "tool_error: prefix stripped"
    "command_blocked" (classify output)

let test_empty_output () =
  check string "empty output classified"
    "empty_output" (classify "")

let test_plain_text_is_parse_error () =
  check string "plain text remains parse_error"
    "parse_error" (classify "something went wrong")

let test_no_error_key_is_unknown () =
  let output = {|{"ok":false,"detail":"missing field"}|} in
  check string "JSON without error key"
    "unknown_error" (classify output)

let test_nested_json_in_error_prefix () =
  let output = {|error: {"ok":false,"error":"path blocked","detail":{"path":"/etc"}}|} in
  check string "nested JSON after prefix"
    "path blocked" (classify output)

let () =
  run "tool_quality_classify"
    [
      ("classify_failure_output", [
           test_case "bare JSON error" `Quick test_bare_json_error;
           test_case "error: prefix stripped" `Quick test_error_prefix_stripped;
           test_case "tool_error: prefix stripped" `Quick test_tool_error_prefix_stripped;
           test_case "empty output" `Quick test_empty_output;
           test_case "plain text -> parse_error" `Quick test_plain_text_is_parse_error;
           test_case "no error key -> unknown_error" `Quick test_no_error_key_is_unknown;
           test_case "nested JSON after prefix" `Quick test_nested_json_in_error_prefix;
         ]);
    ]
