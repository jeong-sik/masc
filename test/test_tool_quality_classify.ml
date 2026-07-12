(** Unit tests for Dashboard_http_tool_quality.classify_failure_output.

    Verifies that error category classification correctly strips known
    prefixes and extracts the actual error key from JSON output. *)

open Alcotest

let classify = Dashboard_http_tool_quality.classify_failure_output

let failure_concentration =
  Dashboard_http_tool_quality.failure_concentration_of_keeper_counts

let test_failure_concentration_top_two () =
  let percentage, keepers =
    failure_concentration
      [ "alpha", 10, 4; "beta", 8, 5; "gamma", 3, 2 ]
  in
  check (float 0.01) "top two failure percentage" 90.0 percentage;
  check (list string) "top two keepers" [ "alpha"; "beta" ] keepers

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

let test_readonly_block_category_preserved () =
  let output =
    {|{"ok":false,"error":"command_blocked_readonly","category":"destructive","blocked_pattern":"cp "}|}
  in
  check string "readonly block keeps category"
    "command_blocked_readonly:destructive" (classify output)

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

let test_path_error_is_normalized () =
  let output =
    {|{"ok":false,"error":"path_not_in_allowed_paths: . (allowed: [/tmp/demo])"}|}
  in
  check string "path boundary error normalized"
    "path_not_in_allowed_paths" (classify output)

let test_sandbox_path_error_is_normalized () =
  let output =
    {|{"ok":false,"error":"path_outside_sandbox: lib/foo.ml (sandbox roots: [/tmp/demo])"}|}
  in
  check string "sandbox path boundary error normalized"
    "path_outside_sandbox" (classify output)

let test_message_error_is_normalized () =
  let output =
    {|{"status":"error","message":"query looks like it may contain secrets; refine it before using web search"}|}
  in
  check string "message-only error normalized"
    "query_secret_like" (classify output)

let test_signaled_status_is_classified () =
  let output =
    {|{"ok":false,"op":"bash","status":{"kind":"signaled","signal":-11},"output":""}|}
  in
  check string "signaled process classified"
    "bash_signaled_-11" (classify output)

let test_timeout_error_is_preserved () =
  let output =
    {|{"ok":false,"error":"command_timed_out","timeout_sec":1.0,"status":{"kind":"timeout"}}|}
  in
  check string "timeout error preserved"
    "command_timed_out" (classify output)

let test_timeout_status_is_classified () =
  let output =
    {|{"ok":false,"op":"bash","status":{"kind":"timeout"},"output":""}|}
  in
  check string "timeout process classified"
    "bash_timeout" (classify output)

let () =
  run "tool_quality_classify"
    [
      ("classify_failure_output", [
           test_case "failure concentration top two" `Quick test_failure_concentration_top_two;
           test_case "bare JSON error" `Quick test_bare_json_error;
           test_case "error: prefix stripped" `Quick test_error_prefix_stripped;
           test_case "tool_error: prefix stripped" `Quick test_tool_error_prefix_stripped;
           test_case "readonly block keeps category" `Quick test_readonly_block_category_preserved;
           test_case "empty output" `Quick test_empty_output;
           test_case "plain text -> parse_error" `Quick test_plain_text_is_parse_error;
           test_case "no error key -> unknown_error" `Quick test_no_error_key_is_unknown;
           test_case "nested JSON after prefix" `Quick test_nested_json_in_error_prefix;
           test_case "path error normalized" `Quick test_path_error_is_normalized;
           test_case "sandbox path error normalized" `Quick
             test_sandbox_path_error_is_normalized;
           test_case "message-only error normalized" `Quick test_message_error_is_normalized;
           test_case "signaled status classified" `Quick test_signaled_status_is_classified;
           test_case "timeout error preserved" `Quick test_timeout_error_is_preserved;
           test_case "timeout status classified" `Quick test_timeout_status_is_classified;
         ]);
    ]
