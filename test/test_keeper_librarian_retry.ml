(* Bounded parse-retry policy for librarian extraction (typed-harness contract
   C6). The retry combinator is pure given a pure [attempt], so these drive it
   with a stub instead of a provider and pin the policy in isolation:
   - parse success returns immediately (no retry),
   - an unparseable response is retried with a corrective nudge,
   - retries are bounded by [max_retries] (initial attempt not counted),
   - a transport failure is surfaced without retry,
   - exactly one nudge is appended per retry. *)

open Alcotest
module R = Masc.Keeper_librarian_runtime
module Lib = Masc.Keeper_librarian
module Types = Agent_sdk.Types

let field_episode_summary = Lib.wire_field_episode_summary
let field_claims = Lib.wire_field_claims
let field_claim = Lib.wire_field_claim
let deprecated_field_confidence = "confidence"
let field_category = Lib.wire_field_category
let field_source_turn = Lib.wire_field_source_turn
let field_source_tool_call_id = Lib.wire_field_source_tool_call_id
let field_open_items = Lib.wire_field_open_items
let field_constraints = Lib.wire_field_constraints
let field_preserved_tool_refs = Lib.wire_field_preserved_tool_refs

let claim_json ?confidence ?(claim = "c") ?(source_turn = `Int 0) () =
  let fields =
    [ field_claim, `String claim
    ; field_category, `String "fact"
    ; field_source_turn, source_turn
    ]
  in
  let fields =
    match confidence with
    | None -> fields
    | Some confidence -> (deprecated_field_confidence, confidence) :: fields
  in
  `Assoc fields
;;

let string_list_json values = `List (List.map (fun value -> `String value) values)

let episode_json
      ?(episode_summary = "s")
      ?(claims = [ claim_json () ])
      ?(open_items = [])
      ?(constraints = [])
      ?(preserved_tool_refs = [])
      ()
  =
  `Assoc
    [ field_episode_summary, `String episode_summary
    ; field_claims, `List claims
    ; field_open_items, string_list_json open_items
    ; field_constraints, string_list_json constraints
    ; field_preserved_tool_refs, string_list_json preserved_tool_refs
    ]
;;

let episode_json_string ?episode_summary ?claims ?open_items ?constraints
      ?preserved_tool_refs () =
  episode_json ?episode_summary ?claims ?open_items ?constraints ?preserved_tool_refs ()
  |> Yojson.Safe.to_string
;;

let minimal_episode_json ?(claim = "c") () =
  episode_json_string ~claims:[ claim_json ~claim () ] ()
;;

(* A minimal valid episode, parsed from known-good JSON, reused as the [Parsed]
   payload so the stub does not have to fabricate the record by hand. *)
let sample_episode () =
  let raw = episode_json_string ~claims:[ claim_json () ] () in
  let inp = { Lib.trace_id = "t"; generation = 0; messages = [] } in
  match Lib.episode_of_output ~now:1_000_000.0 ~generation:inp.generation inp raw with
  | Some ep -> ep
  | None -> Alcotest.fail "fixture episode failed to parse"

let parse_retry_error_to_string = function
  | R.Retry_exhausted_unparseable e -> "unparseable: " ^ e.R.reason
  | R.Retry_transport_failed e -> "transport: " ^ R.extraction_error_to_string e

let unparseable ?raw_evidence reason =
  R.Unparseable (R.unparseable_response ?raw_evidence reason)

let test_operation_returns_missing_context () =
  let input : Lib.input = { trace_id = "typed-operation"; generation = 1; messages = [] } in
  let request : R.operation_request =
    { runtime_id = "typed-runtime"; keeper_id = "typed-keeper"; input }
  in
  match R.execute_operation request with
  | Error R.Eio_context_unavailable -> ()
  | Error error ->
    Alcotest.failf "unexpected operation error: %s" (R.operation_error_to_string error)
  | Ok _ -> Alcotest.fail "operation unexpectedly ran without an installed Eio context"
;;

let nudge_count messages =
  List.length
    (List.filter
       (fun (m : Types.message) ->
         List.exists
           (function
             | Types.Text t -> String.equal t R.parse_retry_nudge
             | _ -> false)
           m.content)
       messages)

let test_succeeds_first_attempt () =
  let ep = sample_episode () in
  let calls = ref 0 in
  let attempt _msgs =
    incr calls;
    R.Parsed ep
  in
  (match R.run_with_parse_retries ~max_retries:2 ~attempt [] with
   | Ok _ -> ()
   | Error e ->
     Alcotest.failf "expected Ok, got Error %s" (parse_retry_error_to_string e));
  check int "no retry when first attempt parses" 1 !calls

let test_retries_then_succeeds () =
  let ep = sample_episode () in
  let calls = ref 0 in
  let attempt _msgs =
    incr calls;
    if !calls < 2 then unparseable "bad json" else R.Parsed ep
  in
  (match R.run_with_parse_retries ~max_retries:2 ~attempt [] with
   | Ok _ -> ()
   | Error e ->
     Alcotest.failf
       "expected Ok after retry, got %s"
       (parse_retry_error_to_string e));
  check int "one retry to recover" 2 !calls

let test_bounded_then_fails () =
  let calls = ref 0 in
  let attempt _msgs =
    incr calls;
    unparseable "still bad"
  in
  (match R.run_with_parse_retries ~max_retries:2 ~attempt [] with
   | Ok _ -> Alcotest.fail "expected Error after exhausting retries"
   | Error (R.Retry_exhausted_unparseable e) ->
     check string "last error surfaced" "still bad" e.R.reason
   | Error (R.Retry_transport_failed e) ->
     Alcotest.failf
       "expected unparseable exhaustion, got transport %s"
       (R.extraction_error_to_string e));
  check int "initial attempt + max_retries" 3 !calls

let test_transport_not_retried () =
  let calls = ref 0 in
  let attempt _msgs =
    incr calls;
    R.Transport_failed R.Provider_timeout
  in
  (match R.run_with_parse_retries ~max_retries:2 ~attempt [] with
   | Ok _ -> Alcotest.fail "expected Error"
   | Error (R.Retry_transport_failed e) ->
     check string "transport error surfaced" "librarian provider timed out"
       (R.extraction_error_to_string e)
   | Error (R.Retry_exhausted_unparseable e) ->
     Alcotest.failf "expected transport error, got unparseable %s" e.R.reason);
  check int "transport failure is not retried" 1 !calls

let test_nudge_appended_each_retry () =
  let ep = sample_episode () in
  let seen = ref [] in
  let calls = ref 0 in
  let attempt msgs =
    incr calls;
    seen := msgs :: !seen;
    if !calls < 3 then unparseable "bad" else R.Parsed ep
  in
  let _ = R.run_with_parse_retries ~max_retries:3 ~attempt [] in
  (* Attempt 1 sees 0 nudges, attempt 2 sees 1, attempt 3 sees 2. *)
  let counts = List.rev_map nudge_count !seen in
  check (list int) "one nudge added per retry" [ 0; 1; 2 ] counts

let test_nonempty_unparseable_evidence_outlives_empty_retry () =
  let calls = ref 0 in
  let attempt _msgs =
    incr calls;
    match !calls with
    | 1 ->
      unparseable
        ~raw_evidence:"first invalid librarian payload"
        "librarian provider returned invalid episode JSON"
    | _ -> unparseable "librarian provider returned empty response"
  in
  match R.run_with_parse_retries ~max_retries:2 ~attempt [] with
  | Ok _ -> Alcotest.fail "expected Error after exhausting retries"
  | Error (R.Retry_transport_failed e) ->
    Alcotest.failf
      "expected unparseable exhaustion, got transport %s"
      (R.extraction_error_to_string e)
  | Error (R.Retry_exhausted_unparseable e) ->
    check string
      "reason stays paired with preserved evidence"
      "librarian provider returned invalid episode JSON"
      e.R.reason;
    check (option string)
      "raw evidence is preserved"
      (Some "first invalid librarian payload")
      e.R.raw_evidence;
    check int "initial attempt + max_retries" 3 !calls

(* Strict parsing with bounded compatibility for real-world librarian provider
   drift. We accept exact JSON and exact JSON-string wrapping only. Markdown
   fences, prose-wrapped JSON, and embedded JSON must fall into the diagnostic
   fallback path instead of being accepted as a structured episode. *)

let parse_ep raw =
  let inp = { Lib.trace_id = "tolerant-t"; generation = 0; messages = [] } in
  Lib.episode_of_output ~now:1_000_000.0 ~generation:inp.generation inp raw
;;

let test_rejects_markdown_wrapped () =
  let raw = "```json\n" ^ episode_json_string ~claims:[] () ^ "\n```" in
  check bool "markdown-wrapped JSON rejected" true (Option.is_none (parse_ep raw))
;;

let test_rejects_prose_wrapped_json () =
  let raw = "Here is the episode you requested:\n" ^ minimal_episode_json () in
  check bool "prose before JSON rejected" true (Option.is_none (parse_ep raw));
  let raw = minimal_episode_json () ^ "\nDone." in
  check bool "prose after JSON rejected" true (Option.is_none (parse_ep raw));
  let raw =
    "Here is the episode you requested:\n\
     ```json\n"
    ^ minimal_episode_json ()
    ^ "\n```\nDone."
  in
  check bool "prose around fenced JSON rejected" true (Option.is_none (parse_ep raw))
;;

let test_parses_json_string_wrapping () =
  let raw =
    `String (episode_json_string ~claims:[] ()) |> Yojson.Safe.to_string
  in
  match parse_ep raw with
  | Some ep ->
    check string "episode_summary" "s" ep.episode_summary;
    check int "claims count" 0 (List.length ep.claims)
  | None -> Alcotest.fail "JSON-string-wrapped object should parse"
;;

let test_rejects_string_source_turn () =
  let raw =
    episode_json_string ~claims:[ claim_json ~source_turn:(`String "3") () ] ()
  in
  check bool "string source_turn rejected" true (Option.is_none (parse_ep raw))
;;

let expect_unexpected_field field raw =
  let inp = { Lib.trace_id = "unexpected-field-t"; generation = 0; messages = [] } in
  match Lib.episode_of_output_result ~now:1_000_000.0 ~generation:0 inp raw with
  | Error (Lib.Unexpected_field got) -> check string "unexpected field" field got
  | Error error ->
    Alcotest.failf
      "expected Unexpected_field %s, got %s"
      field
      (Lib.parse_error_to_string error)
  | Ok _ -> Alcotest.failf "expected Unexpected_field %s" field
;;

let test_rejects_unexpected_episode_field () =
  let raw =
    `Assoc
      [ field_episode_summary, `String "s"
      ; field_claims, `List [ claim_json () ]
      ; field_open_items, `List []
      ; field_constraints, `List []
      ; field_preserved_tool_refs, `List []
      ; "extra_episode_field", `String "drift"
      ]
    |> Yojson.Safe.to_string
  in
  expect_unexpected_field "extra_episode_field" raw
;;

let test_rejects_unexpected_claim_field () =
  let raw =
    episode_json_string
      ~claims:[ claim_json ~confidence:(`Float 0.9) () ]
      ()
  in
  expect_unexpected_field deprecated_field_confidence raw
;;

let test_parse_result_reports_error () =
  let inp = { Lib.trace_id = "typed-error-t"; generation = 0; messages = [] } in
  match Lib.episode_of_output_result ~now:1_000_000.0 ~generation:0 inp "not json" with
  | Error (Lib.Invalid_json _) -> ()
  | Error error ->
    Alcotest.failf "expected Invalid_json, got %s" (Lib.parse_error_to_string error)
  | Ok _ -> Alcotest.fail "expected typed parse error"
;;

let test_rejects_multiple_json_objects () =
  let raw = minimal_episode_json () ^ "\n" ^ minimal_episode_json ~claim:"d" () in
  check bool "multiple JSON objects rejected" true (Option.is_none (parse_ep raw))
;;

let test_rejects_model_thinking_leak () =
  let raw =
    "<thinking>I should output JSON now.</thinking>\n" ^ minimal_episode_json ()
  in
  check bool "thinking leak before JSON rejected" true (Option.is_none (parse_ep raw))
;;

let test_rejects_malformed_json () =
  let raw =
    {|{"episode_summary":"s","claims":[{"claim":"c","category":"fact","source_turn":0}],|}
  in
  check bool "malformed JSON rejected" true (Option.is_none (parse_ep raw))
;;

let test_parses_nested_braces_inside_string () =
  let raw = minimal_episode_json ~claim:"Keep literal { braces } in memory" () in
  match parse_ep raw with
  | Some ep ->
    (match ep.claims with
     | [ claim ] ->
       check string "claim with braces parsed" "Keep literal { braces } in memory" claim.claim
     | claims -> Alcotest.failf "expected one claim, got %d" (List.length claims))
  | None -> Alcotest.fail "valid JSON with braces in a string should parse"
;;

let test_missing_lists_default_to_empty () =
  let raw =
    `Assoc
      [ field_episode_summary, `String "s"
      ; field_claims, `List [ claim_json () ]
      ]
    |> Yojson.Safe.to_string
  in
  match parse_ep raw with
  | Some ep ->
    check int "open_items empty" 0 (List.length ep.open_items);
    check int "constraints empty" 0 (List.length ep.constraints);
    check int "preserved_tool_refs empty" 0 (List.length ep.preserved_tool_refs)
  | None -> Alcotest.fail "missing optional lists should default to empty"
;;

let test_invalid_source_turn_string_rejected () =
  let raw =
    episode_json_string
      ~claims:[ claim_json ~source_turn:(`String "not-a-number") () ]
      ()
  in
  check bool "invalid source_turn rejected" true (Option.is_none (parse_ep raw))
;;

let test_retry_nudge_matches_schema () =
  (* The old nudge listed "confidence" as a claim field; the parser dropped
     confidence in RFC-0247, so the nudge must no longer ask for it. *)
  check (list string) "nudge episode fields match parser fields"
    Lib.wire_episode_fields
    R.parse_retry_episode_fields;
  check (list string) "nudge claim fields match parser fields"
    Lib.wire_claim_fields
    R.parse_retry_claim_fields;
  check bool "nudge episode field list includes claims" true
    (List.mem field_claims R.parse_retry_episode_fields);
  check bool "nudge episode field list includes preserved refs" true
    (List.mem field_preserved_tool_refs R.parse_retry_episode_fields);
  check bool "nudge field list excludes confidence" false
    (List.mem deprecated_field_confidence R.parse_retry_claim_fields);
  check bool "nudge field list includes source_turn" true
    (List.mem field_source_turn R.parse_retry_claim_fields);
  check bool "nudge field list includes source_tool_call_id" true
    (List.mem field_source_tool_call_id R.parse_retry_claim_fields)
;;

let () =
  Eio_main.run @@ fun _env ->
  run "keeper_librarian_retry"
    [
      ( "operation",
        [ test_case
            "missing Eio capabilities is typed failure"
            `Quick
            test_operation_returns_missing_context
        ] );
      ( "parse_retry",
        [
          test_case "succeeds on first attempt" `Quick test_succeeds_first_attempt;
          test_case "retries then succeeds" `Quick test_retries_then_succeeds;
          test_case "bounded then fails" `Quick test_bounded_then_fails;
          test_case "transport not retried" `Quick test_transport_not_retried;
          test_case "nudge appended each retry" `Quick test_nudge_appended_each_retry;
          test_case "non-empty unparseable evidence outlives empty retry" `Quick
            test_nonempty_unparseable_evidence_outlives_empty_retry;
        ] );
      ( "strict_parsing",
        [
          test_case "rejects markdown-wrapped JSON" `Quick test_rejects_markdown_wrapped;
          test_case "rejects prose-wrapped JSON" `Quick test_rejects_prose_wrapped_json;
          test_case "rejects unexpected episode field" `Quick
            test_rejects_unexpected_episode_field;
          test_case "rejects unexpected claim field" `Quick test_rejects_unexpected_claim_field;
          test_case "parses JSON-string-wrapped object" `Quick test_parses_json_string_wrapping;
          test_case "rejects string source_turn" `Quick test_rejects_string_source_turn;
          test_case "parse result reports typed error" `Quick test_parse_result_reports_error;
          test_case "rejects multiple JSON objects" `Quick test_rejects_multiple_json_objects;
          test_case "rejects model thinking leak" `Quick test_rejects_model_thinking_leak;
          test_case "rejects malformed JSON" `Quick test_rejects_malformed_json;
          test_case "parses nested braces inside string" `Quick
            test_parses_nested_braces_inside_string;
          test_case "missing lists default to empty" `Quick test_missing_lists_default_to_empty;
          test_case "rejects invalid source_turn string" `Quick test_invalid_source_turn_string_rejected;
          test_case "retry nudge matches schema" `Quick test_retry_nudge_matches_schema;
        ] );
    ]
