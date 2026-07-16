module U = Masc.Keeper_compaction_unit
module T = Agent_sdk.Types

let message role content : T.message =
  { role; content; name = None; tool_call_id = None; metadata = [] }

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
  Alcotest.(check int) "one atomic unit" 1 (List.length output.compactable_prefix);
  check_exact "closed cycle exact"
    [ U.Closed_tool_cycle cycle ]
    output.compactable_prefix;
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
    output.compactable_prefix;
  check_exact "assistant suffix exact" [ assistant ] output.protected_suffix

let test_open_interstitial_suffix_is_exact () =
  let assistant = message T.Assistant [ use "open" ] in
  let middle_user = text T.User "still waiting" in
  let middle_assistant = text T.Assistant "progress prose" in
  let suffix = [ assistant; middle_user; middle_assistant ] in
  let output = U.partition suffix |> require_ok in
  check_exact "no compactable unit" [] output.compactable_prefix;
  check_exact "interstitial suffix exact" suffix output.protected_suffix

let test_closed_interstitial_cycle_is_atomic () =
  let assistant = message T.Assistant [ use "call" ] in
  let progress = text T.Assistant "tool progress" in
  let completed = message T.User [ result "call" ] in
  let cycle = [ assistant; progress; completed ] in
  let output = U.partition cycle |> require_ok in
  check_exact "closed interstitial cycle"
    [ U.Closed_tool_cycle cycle ]
    output.compactable_prefix;
  check_exact "no protected suffix" [] output.protected_suffix

let test_ordinary_prefix_order () =
  let messages =
    [ text T.System "system"; text T.User "one"; text T.Assistant "two" ]
  in
  let output = U.partition messages |> require_ok in
  check_exact "ordinary order"
    (List.map (fun msg -> U.Ordinary_message msg) messages)
    output.compactable_prefix;
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
        ] )
    ]
