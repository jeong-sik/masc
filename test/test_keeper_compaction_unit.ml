module U = Masc.Keeper_compaction_unit
module T = Agent_sdk.Types

let message ?tool_call_id role content : T.message =
  { role; content; name = None; tool_call_id; metadata = [] }

let text role value = message role [ T.Text value ]

let use id =
  T.ToolUse { id; name = "test_tool"; input = `Assoc [ "id", `String id ] }

let result ?content_blocks id =
  T.ToolResult
    { tool_use_id = id
    ; content = "result:" ^ id
    ; outcome = T.Tool_succeeded
    ; json = Some (`Assoc [ "id", `String id ])
    ; content_blocks
    }

let check_exact label expected actual =
  Alcotest.(check bool) label true (expected = actual)

let require_ok = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "expected structural partition"

let test_signed_parallel_cycle_is_atomic () =
  let assistant =
    message T.Assistant
      [ T.Thinking { content = "private bytes"; signature = Some "signed-bytes" }
      ; use "call-a"
      ; T.RedactedThinking "opaque"
      ; use "call-b"
      ]
  in
  let nested_payload =
    [ T.ToolUse { id = "payload-only"; name = "not-an-anchor"; input = `Null }
    ; result "payload-only"
    ]
  in
  let result_b = message T.User [ result ~content_blocks:nested_payload "call-b" ] in
  let result_a = message T.Tool [ result "call-a" ] in
  let cycle = [ assistant; result_b; result_a ] in
  let output = U.partition cycle |> require_ok in
  Alcotest.(check int) "one atomic unit" 1 (List.length output.closed_prefix);
  check_exact "closed cycle exact"
    [ U.Closed_tool_cycle cycle ]
    output.closed_prefix;
  check_exact "no protected suffix" [] output.protected_suffix;
  match assistant.content with
  | T.Thinking { signature; content } :: _ ->
      Alcotest.(check (option string)) "signature exact" (Some "signed-bytes")
        signature;
      Alcotest.(check string) "thinking exact" "private bytes" content
  | _ -> Alcotest.fail "expected signed thinking"

let test_open_after_assistant_is_protected () =
  let prefix = text T.User "before" in
  let assistant = message T.Assistant [ use "open" ] in
  let output = U.partition [ prefix; assistant ] |> require_ok in
  check_exact "ordinary prefix"
    [ U.Ordinary_message prefix ]
    output.closed_prefix;
  check_exact "assistant suffix exact" [ assistant ] output.protected_suffix

let test_open_interstitial_suffix_is_exact () =
  let assistant = message T.Assistant [ use "open" ] in
  let middle_user = text T.User "still waiting" in
  let middle_assistant = text T.Assistant "progress prose" in
  let suffix = [ assistant; middle_user; middle_assistant ] in
  let output = U.partition suffix |> require_ok in
  check_exact "no closed unit" [] output.closed_prefix;
  check_exact "interstitial suffix exact" suffix output.protected_suffix

let test_closed_interstitial_cycle_is_atomic () =
  let assistant = message T.Assistant [ use "call" ] in
  let progress = text T.Assistant "tool progress" in
  let completed = message T.User [ result "call" ] in
  let cycle = [ assistant; progress; completed ] in
  let output = U.partition cycle |> require_ok in
  check_exact "closed interstitial cycle"
    [ U.Closed_tool_cycle cycle ]
    output.closed_prefix;
  check_exact "no protected suffix" [] output.protected_suffix

let test_tool_id_can_repeat_after_closed_cycle () =
  let cycle =
    [ message T.Assistant [ use "provider-id" ]
    ; message T.User [ result "provider-id" ] ] in
  let output = U.partition (cycle @ cycle) |> require_ok in
  check_exact "cycles remain distinct"
    [ U.Closed_tool_cycle cycle; U.Closed_tool_cycle cycle ]
    output.closed_prefix

let test_ordinary_prefix_order () =
  let messages =
    [ text T.System "system"; text T.User "one"; text T.Assistant "two" ]
  in
  let output = U.partition messages |> require_ok in
  check_exact "ordinary order"
    (List.map (fun msg -> U.Ordinary_message msg) messages)
    output.closed_prefix;
  check_exact "empty suffix" [] output.protected_suffix

let test_orphan_result_error () =
  match U.partition [ message T.User [ result "orphan" ] ] with
  | Error (U.Orphan_tool_result { message_index = 0; tool_use_id = "orphan" }) ->
      ()
  | _ -> Alcotest.fail "expected typed orphan ToolResult"

let test_duplicate_result_error () =
  let assistant = message T.Assistant [ use "a"; use "b" ] in
  let first = message T.User [ result "a" ] in
  let duplicate = message T.User [ result "a" ] in
  match U.partition [ assistant; first; duplicate ] with
  | Error (U.Duplicate_tool_result { message_index = 2; tool_use_id = "a" }) ->
      ()
  | _ -> Alcotest.fail "expected typed duplicate ToolResult"

let test_unknown_result_error () =
  let assistant = message T.Assistant [ use "known" ] in
  let unknown = message T.User [ result "unknown" ] in
  match U.partition [ assistant; unknown ] with
  | Error (U.Unknown_tool_result { message_index = 1; tool_use_id = "unknown" }) ->
      ()
  | _ -> Alcotest.fail "expected typed unknown ToolResult"

let test_open_result_role_error () =
  let assistant = message T.Assistant [ use "call" ] in
  let invalid = message T.Assistant [ result "call" ] in
  match U.partition [ assistant; invalid ] with
  | Error (U.Non_result_tool_role { message_index = 1; tool_use_id = "call" }) ->
      ()
  | _ -> Alcotest.fail "expected typed ToolResult role error"

let test_non_assistant_tool_use_error () =
  match U.partition [ message T.User [ use "invalid" ] ] with
  | Error
      (U.Non_assistant_tool_use { message_index = 0; tool_use_id = "invalid" }) ->
      ()
  | _ -> Alcotest.fail "expected typed non-assistant ToolUse"

let test_duplicate_tool_use_error () =
  match U.partition [ message T.Assistant [ use "same"; use "same" ] ] with
  | Error (U.Duplicate_tool_use_id { message_index = 0; tool_use_id = "same" }) ->
      ()
  | _ -> Alcotest.fail "expected typed duplicate ToolUse"

let test_mixed_request_result_error () =
  match U.partition [ message T.Assistant [ use "same"; result "same" ] ] with
  | Error
      (U.Tool_request_contains_result
        { message_index = 0; tool_use_id = "same" }) ->
      ()
  | _ -> Alcotest.fail "expected typed mixed request/result"

let test_empty_tool_use_id_error () =
  List.iter
    (fun tool_use_id ->
       match U.partition [ message T.Assistant [ use tool_use_id ] ] with
       | Error
           (U.Empty_tool_use_id
             { message_index = 0; block_index = 0; tool_use_id = actual }) ->
         Alcotest.(check string) "raw empty ToolUse id" tool_use_id actual
       | _ -> Alcotest.fail "expected typed empty ToolUse id")
    [ ""; " \t\n" ]
;;

let test_empty_tool_result_id_error () =
  List.iter
    (fun tool_use_id ->
       let request = message T.Assistant [ use "expected" ] in
       let response = message T.Tool [ result tool_use_id ] in
       match U.partition [ request; response ] with
       | Error
           (U.Empty_tool_result_id
             { message_index = 1; block_index = 0; tool_use_id = actual }) ->
         Alcotest.(check string) "raw empty ToolResult id" tool_use_id actual
       | _ -> Alcotest.fail "expected typed empty ToolResult id")
    [ ""; " \t\n" ]
;;

let test_parallel_empty_tool_use_id_error () =
  let request =
    message T.Assistant
      [ use "call-a"; T.Text "between"; use " \t"; use "call-b" ]
  in
  match U.partition [ request ] with
  | Error
      (U.Empty_tool_use_id
        { message_index = 0; block_index = 2; tool_use_id = " \t" }) ->
    ()
  | _ -> Alcotest.fail "expected typed empty parallel ToolUse id"
;;

let test_parallel_empty_tool_result_id_error () =
  let request = message T.Assistant [ use "call-a"; use "call-b" ] in
  let response =
    message T.Tool [ result "call-a"; T.Text "between"; result "\n " ]
  in
  match U.partition [ request; response ] with
  | Error
      (U.Empty_tool_result_id
        { message_index = 1; block_index = 2; tool_use_id = "\n " }) ->
    ()
  | _ -> Alcotest.fail "expected typed empty parallel ToolResult id"
;;

let test_message_content_tool_id_mismatch_error () =
  let request = message T.Assistant [ use "content-id" ] in
  let response =
    message ~tool_call_id:"message-id" T.Tool [ result "content-id" ]
  in
  match U.partition [ request; response ] with
  | Error
      (U.Message_tool_call_id_mismatch
        { message_index = 1
        ; message_tool_call_id = "message-id"
        ; content_tool_use_ids = [ "content-id" ]
        }) ->
    ()
  | _ -> Alcotest.fail "expected typed message/content ToolResult id mismatch"
;;

let test_message_tool_id_without_result_error () =
  let message = message ~tool_call_id:"stray-id" T.Tool [ T.Text "no result" ] in
  match U.partition [ message ] with
  | Error
      (U.Message_tool_call_id_mismatch
        { message_index = 0
        ; message_tool_call_id = "stray-id"
        ; content_tool_use_ids = []
        }) ->
    ()
  | _ -> Alcotest.fail "expected typed message ToolResult id mismatch"
;;

let test_nonblank_tool_ids_remain_exact () =
  let exact_id = "  exact-id  " in
  let request = message T.Assistant [ use exact_id ] in
  let response =
    message ~tool_call_id:exact_id T.Tool [ result exact_id ]
  in
  let cycle = [ request; response ] in
  let output = U.partition cycle |> require_ok in
  check_exact
    "nonblank id is not normalized"
    [ U.Closed_tool_cycle cycle ]
    output.closed_prefix;
  match
    U.partition
      [ request; message ~tool_call_id:"exact-id" T.Tool [ result "exact-id" ] ]
  with
  | Error (U.Unknown_tool_result { message_index = 1; tool_use_id = "exact-id" }) ->
    ()
  | _ -> Alcotest.fail "trimmed ToolResult id must not match the raw ToolUse id"
;;

let test_invalid_identity_prevents_plan_callback () =
  let plan_calls = ref 0 in
  let outcome =
    U.partition [ message T.Assistant [ use " \t" ] ]
    |> Result.map (fun (partition : U.partition) ->
      incr plan_calls;
      partition.closed_prefix)
  in
  (match outcome with
   | Error (U.Empty_tool_use_id _) -> ()
   | _ -> Alcotest.fail "expected invalid identity before plan callback");
  Alcotest.(check int) "plan callback count" 0 !plan_calls
;;

let () =
  Alcotest.run "keeper_compaction_unit"
    [ ( "partition"
      , [ Alcotest.test_case "signed parallel cycle exact" `Quick
            test_signed_parallel_cycle_is_atomic
        ; Alcotest.test_case "open after assistant" `Quick
            test_open_after_assistant_is_protected
        ; Alcotest.test_case "open interstitial suffix" `Quick
            test_open_interstitial_suffix_is_exact
        ; Alcotest.test_case "closed interstitial cycle" `Quick
            test_closed_interstitial_cycle_is_atomic
        ; Alcotest.test_case "tool id reuse after closed cycle" `Quick
            test_tool_id_can_repeat_after_closed_cycle
        ; Alcotest.test_case "ordinary prefix order" `Quick
            test_ordinary_prefix_order
        ; Alcotest.test_case "orphan result" `Quick test_orphan_result_error
        ; Alcotest.test_case "duplicate result" `Quick
            test_duplicate_result_error
        ; Alcotest.test_case "unknown result" `Quick test_unknown_result_error
        ; Alcotest.test_case "invalid result role" `Quick
            test_open_result_role_error
        ; Alcotest.test_case "non-assistant use" `Quick
            test_non_assistant_tool_use_error
        ; Alcotest.test_case "duplicate use" `Quick test_duplicate_tool_use_error
        ; Alcotest.test_case "mixed request/result" `Quick
            test_mixed_request_result_error
        ; Alcotest.test_case "empty ToolUse id" `Quick
            test_empty_tool_use_id_error
        ; Alcotest.test_case "empty ToolResult id" `Quick
            test_empty_tool_result_id_error
        ; Alcotest.test_case "parallel empty ToolUse id" `Quick
            test_parallel_empty_tool_use_id_error
        ; Alcotest.test_case "parallel empty ToolResult id" `Quick
            test_parallel_empty_tool_result_id_error
        ; Alcotest.test_case "message/content id mismatch" `Quick
            test_message_content_tool_id_mismatch_error
        ; Alcotest.test_case "message id without result" `Quick
            test_message_tool_id_without_result_error
        ; Alcotest.test_case "nonblank ids remain exact" `Quick
            test_nonblank_tool_ids_remain_exact
        ; Alcotest.test_case "invalid identity stops plan callback" `Quick
            test_invalid_identity_prevents_plan_callback
        ] )
    ]
