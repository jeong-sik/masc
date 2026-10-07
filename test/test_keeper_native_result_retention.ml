module T = Agent_core.Types
module Retention = Masc.Keeper_native_result_retention

let message role content : T.message =
  {role; content; name=None; tool_call_id=None; metadata=[]}

let result id content =
  T.ToolResult {tool_use_id=id; content; outcome=T.Tool_succeeded;
               json=None; content_blocks=None}

let use id = T.ToolUse {id; name="effect"; input=`Assoc []}
let receipt = result "reused-id" "same payload"
let old_cycle = [message T.Assistant [use "reused-id"]; message T.Tool [receipt]]
let seed = old_cycle @ [T.user_msg "new operation"]
let current_request = message T.Assistant [use "reused-id"]
let current_result = message T.Tool [receipt]

let check label expected messages results =
  Alcotest.(check bool) label expected (Retention.retains ~seed ~messages ~results)

let test_previous_receipt_does_not_settle_current_call () =
  check "prior identical receipt cannot close current checkpoint gap" false
    (seed @ [current_request]) [receipt];
  check "current occurrence closes this call" true
    (seed @ [current_request; current_result]) [receipt]

let test_one_occurrence_cannot_settle_two_invocations () =
  check "one occurrence for two canonical invocations remains fenced" false
    (seed @ [current_request; current_result; current_request]) [receipt; receipt];
  check "both current occurrences are retained" true
    (seed @ [current_request; current_result; current_request; current_result])
    [receipt; receipt]

let test_changed_seed_or_payload_rejects () =
  check "receipt in an unrelated transcript does not authorize fallback" false
    [current_request; current_result] [receipt];
  check "different result body does not satisfy journal receipt" false
    (seed @ [current_request; message T.Tool [result "reused-id" "different"]]) [receipt]

let test_empty_result_set_preserves_provider_projection () =
  check "provider-only media projection has no settled results to lose" true
    [T.user_msg "existing media fallback projection"] []

let () =
  Alcotest.run "native result retention"
    ["scope and occurrence",
     [Alcotest.test_case "prior identical result" `Quick test_previous_receipt_does_not_settle_current_call;
      Alcotest.test_case "repeated invocation" `Quick test_one_occurrence_cannot_settle_two_invocations;
      Alcotest.test_case "exact transcript and payload" `Quick test_changed_seed_or_payload_rejects;
      Alcotest.test_case "provider-only projection" `Quick test_empty_result_set_preserves_provider_projection]]
