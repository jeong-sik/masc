(** Unit tests for objective tool failure observation. *)

open Alcotest

let classify = Dashboard_http_tool_quality.classify_failure_output

let test_bare_json_error () =
  let output = {|{"ok":false,"error":"Invalid task state"}|} in
  check string "bare JSON extracts error key"
    "Invalid task state" (classify output)

let test_error_prefix_is_unstructured () =
  let output = {|error: {"ok":false,"error":"❌ Invalid task state: Cannot start"}|} in
  check string "prefix is not guessed"
    "unstructured_failure" (classify output)

let test_tool_error_prefix_is_unstructured () =
  let output = {|tool_error: {"ok":false,"error":"command_blocked"}|} in
  check string "prefix is not guessed"
    "unstructured_failure" (classify output)

let test_empty_output () =
  check string "empty output classified"
    "empty_output" (classify "")

let test_plain_text_is_parse_error () =
  check string "plain text remains unstructured"
    "unstructured_failure" (classify "something went wrong")

let test_no_error_key_is_unknown () =
  let output = {|{"ok":false,"detail":"missing field"}|} in
  check string "JSON without error key"
    "unknown_error" (classify output)

let test_path_error_is_preserved () =
  let output =
    {|{"ok":false,"error":"path_not_in_allowed_paths: . (allowed: [/tmp/demo])"}|}
  in
  check string "path boundary error preserved exactly"
    "path_not_in_allowed_paths: . (allowed: [/tmp/demo])" (classify output)

let test_sandbox_path_error_is_preserved () =
  let output =
    {|{"ok":false,"error":"path_outside_sandbox: lib/foo.ml (sandbox roots: [/tmp/demo])"}|}
  in
  check string "sandbox path boundary error preserved exactly"
    "path_outside_sandbox: lib/foo.ml (sandbox roots: [/tmp/demo])" (classify output)

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
           test_case "bare JSON error" `Quick test_bare_json_error;
           test_case "error: prefix remains unstructured" `Quick test_error_prefix_is_unstructured;
           test_case "tool_error: prefix remains unstructured" `Quick test_tool_error_prefix_is_unstructured;
           test_case "empty output" `Quick test_empty_output;
           test_case "plain text -> unstructured" `Quick test_plain_text_is_parse_error;
           test_case "no error key -> unknown_error" `Quick test_no_error_key_is_unknown;
           test_case "path error preserved" `Quick test_path_error_is_preserved;
           test_case "sandbox path error preserved" `Quick
             test_sandbox_path_error_is_preserved;
           test_case "signaled status classified" `Quick test_signaled_status_is_classified;
           test_case "timeout error preserved" `Quick test_timeout_error_is_preserved;
           test_case "timeout status classified" `Quick test_timeout_status_is_classified;
         ]);
    ]
