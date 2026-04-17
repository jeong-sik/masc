open Alcotest

module KET = Masc_mcp.Keeper_exec_tools

let payload_kind = function
  | KET.Structured_success -> "structured_success"
  | KET.Structured_error -> "structured_error"
  | KET.Plain_text -> "plain_text"
  | KET.Malformed_structured _ -> "malformed_structured"

let check_kind ~msg expected payload =
  check string msg expected
    (payload_kind (KET.classify_tool_result_payload payload))

let test_plain_text_is_success_shape () =
  check_kind
    ~msg:"plain text stays plain_text"
    "plain_text"
    "## Search Results\n\n- keeper_fs_read"

let test_plain_text_with_leading_whitespace_stays_plain () =
  check_kind
    ~msg:"leading whitespace plain text stays plain_text"
    "plain_text"
    "  completed successfully"

let test_structured_success_json () =
  check_kind
    ~msg:"ok=true object is structured_success"
    "structured_success"
    {|{"ok":true,"result":"done"}|}

let test_structured_error_json () =
  check_kind
    ~msg:"error object is structured_error"
    "structured_error"
    {|{"ok":false,"error":"boom"}|}

let test_structured_array_counts_as_success_shape () =
  check_kind
    ~msg:"json array remains structured_success"
    "structured_success"
    {|[{"task_id":"T-1"}]|}

let test_malformed_json_like_payload_detected () =
  match KET.classify_tool_result_payload {|{"ok":true|} with
  | KET.Malformed_structured detail ->
    check bool "detail mentions JSON parse error"
      true (String.length detail > 0)
  | other ->
    fail
      (Printf.sprintf "expected malformed_structured, got %s"
         (payload_kind other))

let () =
  run "Keeper_exec_tools" [
    ("classify_tool_result_payload", [
      test_case "plain text" `Quick test_plain_text_is_success_shape;
      test_case "plain text with leading whitespace" `Quick
        test_plain_text_with_leading_whitespace_stays_plain;
      test_case "structured success object" `Quick
        test_structured_success_json;
      test_case "structured error object" `Quick
        test_structured_error_json;
      test_case "structured array" `Quick
        test_structured_array_counts_as_success_shape;
      test_case "malformed json-like payload" `Quick
        test_malformed_json_like_payload_detected;
    ]);
  ]
