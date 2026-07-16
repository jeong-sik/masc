module U = Masc.Keeper_compaction_unit
module P = Masc.Keeper_compaction_unit_plan
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

let plan_json ~kept ~dropped ~summarized =
  let ints values = `List (List.map (fun value -> `Int value) values) in
  let summary (unit_index, value) =
    `Assoc [ "unit_index", `Int unit_index; "summary", `String value ]
  in
  `Assoc
    [ "kept_indices", ints kept
    ; "dropped_indices", ints dropped
    ; "summarized_units", `List (List.map summary summarized)
    ]

let test_unit_plan_contract () =
  let ordinary = text T.User "ordinary" in
  let request = message T.Assistant [ use "closed" ] in
  let result = message T.Tool [ result "closed" ] in
  let open_request = message T.Assistant [ use "open" ] in
  let progress = text T.Assistant "in-flight" in
  let source = U.partition [ ordinary; request; result; open_request; progress ] |> require_ok in
  let input = P.input_json source in
  let units = Yojson.Safe.Util.(member "units" input |> to_list) in
  Alcotest.(check int) "protected suffix excluded" 2 (List.length units);
  check_exact "no must_keep heuristic" `Null
    Yojson.Safe.Util.(member "must_keep" (List.nth units 1));
  let decode ~kept ~dropped ~summarized =
    P.decode ~source (plan_json ~kept ~dropped ~summarized)
  in
  let summarized_cycle =
    decode ~kept:[ 0 ] ~dropped:[] ~summarized:[ 1, "cycle summary" ]
    |> Result.get_ok
  in
  check_exact "closed pair summarized atomically"
    [ ordinary; text T.Assistant "cycle summary"; open_request; progress ]
    (P.apply summarized_cycle);
  let observed = P.observation summarized_cycle in
  Alcotest.(check int) "two source messages summarized" 2
    observed.summarized_source_messages;
  Alcotest.(check int) "one summary emitted" 1 observed.emitted_summary_messages;
  let dropped_cycle =
    decode ~kept:[ 0 ] ~dropped:[ 1 ] ~summarized:[] |> Result.get_ok
  in
  check_exact "closed pair dropped atomically"
    [ ordinary; open_request; progress ]
    (P.apply dropped_cycle);
  let kept_cycle =
    decode ~kept:[ 1 ] ~dropped:[] ~summarized:[ 0, "  exact summary  " ]
    |> Result.get_ok
  in
  check_exact "summary bytes and kept cycle stay exact"
    [ text T.Assistant "  exact summary  "; request; result; open_request; progress ]
    (P.apply kept_cycle);
  let disjoint_messages =
    [ text T.User "zero"; request; result; text T.User "two" ]
  in
  let disjoint_source = U.partition disjoint_messages |> require_ok in
  let disjoint =
    P.decode ~source:disjoint_source
      (plan_json ~kept:[ 1 ] ~dropped:[]
         ~summarized:[ 0, "summary zero"; 2, "summary two" ])
    |> Result.get_ok
  in
  check_exact "disjoint summaries retain chronology"
    [ text T.Assistant "summary zero"; request; result; text T.Assistant "summary two" ]
    (P.apply disjoint);
  let is_error expected json =
    match P.decode ~source json with
    | Error actual -> expected actual
    | Ok _ -> false
  in
  Alcotest.(check bool) "blank summary rejected" true
    (is_error
       (function P.Blank_summary 1 -> true | _ -> false)
       (plan_json ~kept:[ 0 ] ~dropped:[] ~summarized:[ 1, " " ]));
  Alcotest.(check bool) "duplicate decision rejected" true
    (is_error
       (function P.Duplicate_decision 0 -> true | _ -> false)
       (plan_json ~kept:[ 0 ] ~dropped:[ 0 ] ~summarized:[ 1, "x" ]));
  Alcotest.(check bool) "missing decision rejected" true
    (is_error
       (function P.Missing_decision 1 -> true | _ -> false)
       (plan_json ~kept:[ 0 ] ~dropped:[] ~summarized:[]));
  Alcotest.(check bool) "out-of-range rejected" true
    (is_error
       (function P.Index_out_of_range { index = 2; unit_count = 2 } -> true | _ -> false)
       (plan_json ~kept:[ 0; 2 ] ~dropped:[ 1 ] ~summarized:[]));
  Alcotest.(check bool) "all-kept no-op rejected" true
    (is_error
       (function P.No_compaction -> true | _ -> false)
       (plan_json ~kept:[ 0; 1 ] ~dropped:[] ~summarized:[]));
  Alcotest.(check bool) "unknown field rejected" true
    (is_error
       (function P.Unknown_field "repair" -> true | _ -> false)
       (`Assoc
          [ "kept_indices", `List [ `Int 0 ]
          ; "dropped_indices", `List [ `Int 1 ]
          ; "summarized_units", `List []
          ; "repair", `Bool true
          ]))

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
        ; Alcotest.test_case "typed unit plan" `Quick test_unit_plan_contract
        ] )
    ]
