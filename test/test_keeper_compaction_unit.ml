module U = Masc.Keeper_compaction_unit
module E = Masc.Keeper_compaction_eligible_history
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

let require_summary value =
  match E.Summary.create value with
  | Ok summary -> summary
  | Error E.Summary.Empty -> Alcotest.fail "expected non-empty summary"

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

let test_eligible_history_preserves_protected_units_and_roles () =
  let system = text T.System "system exact" in
  let user = { (text T.User "user detail") with name = Some "alice" } in
  let assistant = text T.Assistant "assistant detail" in
  let provider_bound =
    { (text T.Assistant "provider bound") with
      metadata = [ "provider_message_id", `String "opaque-id" ]
    }
  in
  let tool_request = message T.Assistant [ use "call" ] in
  let progress = text T.Assistant "tool progress" in
  let tool_result = message T.User [ result "call" ] in
  let reasoning =
    message
      T.Assistant
      [ T.ReasoningDetails
          { reasoning_content = Some "opaque"; details = [] }
      ]
  in
  let open_request = message T.Assistant [ use "open" ] in
  let open_progress = text T.User "still running" in
  let source_messages =
    [ system
    ; user
    ; assistant
    ; provider_bound
    ; tool_request
    ; progress
    ; tool_result
    ; reasoning
    ; open_request
    ; open_progress
    ]
  in
  let source = E.of_messages source_messages |> require_ok in
  let eligible = E.eligible_units source in
  Alcotest.(check (list int))
    "only pure User/Assistant units"
    [ 1; 2 ]
    (List.map E.unit_index eligible);
  match eligible with
  | [ user_unit; assistant_unit ] ->
    let decisions =
      [ E.summarize user_unit (require_summary "user summary")
      ; E.drop assistant_unit
      ]
    in
    (match E.apply source decisions with
     | Error _ -> Alcotest.fail "eligible plan was rejected"
     | Ok (E.No_compaction _) -> Alcotest.fail "changed plan reported no compaction"
     | Ok (E.Compacted messages) ->
       let summarized_user = { user with content = [ T.Text "user summary" ] } in
       check_exact
         "protected units and open suffix remain exact"
         [ system
         ; summarized_user
         ; provider_bound
         ; tool_request
         ; progress
         ; tool_result
         ; reasoning
         ; open_request
         ; open_progress
         ]
         messages)
  | _ -> Alcotest.fail "unexpected eligible unit set"

let test_eligible_history_rejects_incomplete_or_foreign_decisions () =
  let source =
    E.of_messages [ text T.User "one"; text T.Assistant "two" ] |> require_ok
  in
  let first, second =
    match E.eligible_units source with
    | [ first; second ] -> first, second
    | _ -> Alcotest.fail "expected two eligible units"
  in
  (match E.apply source [ E.keep first ] with
   | Error (E.Missing_decisions [ index ]) ->
     Alcotest.(check int) "missing exact unit" (E.unit_index second) index
   | _ -> Alcotest.fail "missing decision was not explicit");
  (match E.apply source [ E.keep first; E.keep first; E.keep second ] with
   | Error (E.Duplicate_decision index) ->
     Alcotest.(check int) "duplicate exact unit" (E.unit_index first) index
   | _ -> Alcotest.fail "duplicate decision was not explicit");
  let foreign_source = E.of_messages [ text T.User "foreign" ] |> require_ok in
  let foreign = List.hd (E.eligible_units foreign_source) in
  match E.apply source [ E.keep foreign; E.keep second ] with
  | Error (E.Unit_source_mismatch 0) -> ()
  | _ -> Alcotest.fail "foreign decision was not explicit"

let test_eligible_history_keep_is_exact_no_compaction () =
  let original = { (text T.User "exact") with name = Some "speaker" } in
  let source = E.of_messages [ original ] |> require_ok in
  let unit = List.hd (E.eligible_units source) in
  match E.apply source [ E.keep unit ] with
  | Ok (E.No_compaction messages) -> check_exact "exact keep" [ original ] messages
  | _ -> Alcotest.fail "keep-only plan did not report no compaction"

let test_eligible_history_preserves_text_block_boundaries () =
  let original = message T.User [ T.Text "first"; T.Text "second" ] in
  let source = E.of_messages [ original ] |> require_ok in
  let unit = List.hd (E.eligible_units source) in
  Alcotest.(check (list string))
    "exact text blocks"
    [ "first"; "second" ]
    (E.unit_text_blocks unit);
  let unchanged = E.summarize unit (require_summary "first") in
  match E.apply source [ unchanged ] with
  | Ok (E.Compacted [ summarized ]) ->
    check_exact
      "summary replaces content structurally"
      [ { original with content = [ T.Text "first" ] } ]
      [ summarized ]
  | _ -> Alcotest.fail "structural summary was not applied"

let test_identical_summary_is_no_compaction () =
  let original = text T.Assistant "same" in
  let source = E.of_messages [ original ] |> require_ok in
  let unit = List.hd (E.eligible_units source) in
  match E.apply source [ E.summarize unit (require_summary "same") ] with
  | Ok (E.No_compaction messages) -> check_exact "identical summary" [ original ] messages
  | _ -> Alcotest.fail "identical summary reported a false compaction"

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
    ; ( "eligible_history"
      , [ Alcotest.test_case "protected exact and role preserving" `Quick
            test_eligible_history_preserves_protected_units_and_roles
        ; Alcotest.test_case "decision coverage and source binding" `Quick
            test_eligible_history_rejects_incomplete_or_foreign_decisions
        ; Alcotest.test_case "keep-only is exact no-compaction" `Quick
            test_eligible_history_keep_is_exact_no_compaction
        ; Alcotest.test_case "text block boundaries remain exact" `Quick
            test_eligible_history_preserves_text_block_boundaries
        ; Alcotest.test_case "identical summary is no-compaction" `Quick
            test_identical_summary_is_no_compaction
        ] )
    ]
