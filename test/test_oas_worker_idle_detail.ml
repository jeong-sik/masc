(** Idle detail enrichment tests for [test_oas_worker]. *)

open Masc_mcp

let contains_substring ~needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    i + n <= h
    && (String.sub haystack i n = needle || loop (i + 1))
  in
  n = 0 || loop 0
;;

let make_assistant_tool_use_msg name : Agent_sdk.Types.message =
  { Agent_sdk.Types.role = Agent_sdk.Types.Assistant
  ; content = [ Agent_sdk.Types.ToolUse { id = "call-1"; name; input = `Assoc [] } ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let test_enrich_idle_detail_with_tool () =
  let detail = "Idle detected after 3 identical turns" in
  let messages = [ make_assistant_tool_use_msg "my_tool" ] in
  let result = Cascade_runner.enrich_idle_detail detail messages in
  Alcotest.(check bool)
    "contains original prefix"
    true
    (String.starts_with ~prefix:detail result);
  Alcotest.(check bool)
    "appends tool name"
    true
    (contains_substring ~needle:"(tool: my_tool)" result)
;;

let test_enrich_idle_detail_no_tool () =
  let detail = "Idle detected after 3 identical turns" in
  let messages : Agent_sdk.Types.message list =
    [ { Agent_sdk.Types.role = Agent_sdk.Types.User
      ; content = [ Agent_sdk.Types.Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let result = Cascade_runner.enrich_idle_detail detail messages in
  Alcotest.(check string) "unchanged when no tool" detail result
;;

let test_enrich_idle_detail_empty_messages () =
  let detail = "Idle detected: no progress" in
  let result = Cascade_runner.enrich_idle_detail detail [] in
  Alcotest.(check string) "unchanged with empty messages" detail result
;;

let test_enrich_idle_detail_non_idle_error () =
  let detail = "Rate limit exceeded" in
  let messages = [ make_assistant_tool_use_msg "some_tool" ] in
  let result = Cascade_runner.enrich_idle_detail detail messages in
  Alcotest.(check string) "non-idle error unchanged" detail result
;;

let test_enrich_idle_detail_picks_last_tool () =
  let detail = "Idle detected after 3 identical turns" in
  let messages =
    [ make_assistant_tool_use_msg "first_tool"; make_assistant_tool_use_msg "last_tool" ]
  in
  let expected = detail ^ " (tool: last_tool)" in
  let result = Cascade_runner.enrich_idle_detail detail messages in
  Alcotest.(check string) "exact string with last tool" expected result
;;

let cases =
  [ Alcotest.test_case
      "idle error with tool appends tool name"
      `Quick
      test_enrich_idle_detail_with_tool
  ; Alcotest.test_case
      "idle error with no tool is unchanged"
      `Quick
      test_enrich_idle_detail_no_tool
  ; Alcotest.test_case
      "idle error with empty messages is unchanged"
      `Quick
      test_enrich_idle_detail_empty_messages
  ; Alcotest.test_case
      "non-idle error is never modified"
      `Quick
      test_enrich_idle_detail_non_idle_error
  ; Alcotest.test_case
      "last tool name wins over earlier ones"
      `Quick
      test_enrich_idle_detail_picks_last_tool
  ]
;;
