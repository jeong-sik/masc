(* #9851: governance judge parse recovery — tests for the secondary
   brace-balanced block extraction used when [Lenient_json.parse] falls
   through to the {raw: <text>} sentinel because the LLM prefixed prose
   before the JSON. *)

open Alcotest
open Masc_mcp

let test_no_brace_returns_none () =
  let out = Judge_json_recovery.extract_balanced_object "no json here" in
  check (option string) "plain prose has no json block" None out

let test_balanced_object_after_prose () =
  let raw = "Here is the judgment: {\"items\": []}\nThanks!" in
  match Judge_json_recovery.extract_balanced_object raw with
  | Some block -> check string "extracts object after prose" "{\"items\": []}" block
  | None -> fail "expected Some with the balanced object"

let test_nested_object () =
  let raw = "prefix {\"a\": {\"b\": 1}, \"c\": 2} suffix" in
  match Judge_json_recovery.extract_balanced_object raw with
  | Some block ->
      check string "depth-2 object closes correctly"
        "{\"a\": {\"b\": 1}, \"c\": 2}" block
  | None -> fail "expected Some"

let test_braces_inside_string_ignored () =
  (* A stray { inside a string literal must NOT open a new scope, so the
     outer object should close at the matching }. *)
  let raw = "before {\"text\": \"hello {world}\"} after" in
  match Judge_json_recovery.extract_balanced_object raw with
  | Some block ->
      check string "brace inside string is content, not scope"
        "{\"text\": \"hello {world}\"}" block
  | None -> fail "expected Some"

let test_escaped_quote_inside_string () =
  let raw = "prefix {\"msg\": \"quote \\\"inside\\\" value\"}" in
  match Judge_json_recovery.extract_balanced_object raw with
  | Some block ->
      check string "escaped quotes do not close the string"
        "{\"msg\": \"quote \\\"inside\\\" value\"}" block
  | None -> fail "expected Some"

let test_unbalanced_returns_none () =
  let raw = "prefix {\"items\": [" in
  let out = Judge_json_recovery.extract_balanced_object raw in
  check (option string) "truncated object returns None" None out

let () =
  run "judge_json_recovery" [
    "extract_balanced_object", [
      test_case "no brace → None" `Quick test_no_brace_returns_none;
      test_case "balanced object after prose" `Quick
        test_balanced_object_after_prose;
      test_case "nested object" `Quick test_nested_object;
      test_case "braces inside string are ignored" `Quick
        test_braces_inside_string_ignored;
      test_case "escaped quote inside string" `Quick
        test_escaped_quote_inside_string;
      test_case "unbalanced → None" `Quick test_unbalanced_returns_none;
    ]
  ]
