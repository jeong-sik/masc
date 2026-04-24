(** #9777: regression tests for [Tool_board.detect_truncated_markdown_with_reason].

    Each case names the truncation pattern under test and asserts both
    that detection fires and that the FIRST signal returned is the
    expected one — so we lock in the priority order at the structural
    level (fence > inline tick > double-asterisk > unfinished link/image). *)

open Alcotest
open Masc_mcp

let signal_eq a b =
  Tool_board.truncation_signal_to_string a
  = Tool_board.truncation_signal_to_string b

let signal_pp ppf s =
  Format.fprintf ppf "%s" (Tool_board.truncation_signal_to_string s)

let signal_t = testable signal_pp signal_eq

let detect = Tool_board.detect_truncated_markdown_with_reason

(* ---- Negative cases (should NOT trigger detection) ----------------- *)

let test_complete_text_no_signal () =
  check (option signal_t) "complete sentence"
    None (detect "Hello, this is a complete sentence.")

let test_balanced_fence_no_signal () =
  check (option signal_t) "balanced ``` fence"
    None (detect "Look:\n```ocaml\nlet x = 1\n```\nDone.")

let test_balanced_inline_tick_no_signal () =
  check (option signal_t) "balanced inline `let x` ticks"
    None (detect "Use `let` and `in` together.")

let test_double_asterisk_in_inline_code_no_signal () =
  check (option signal_t) "glob in balanced inline code"
    None (detect "Run `ls **/*.ml` before submitting.")

let test_underscore_in_identifier_not_truncation () =
  (* Identifiers with underscores must NOT trigger detection
     (the original detector was deliberately conservative on _). *)
  check (option signal_t) "snake_case identifier"
    None (detect "See snake_case_var and another_one.")

let test_paren_in_prose_not_unfinished_link () =
  (* Plain parens in prose without [text] before should not trigger. *)
  check (option signal_t) "trailing prose paren"
    None (detect "(this is a parenthetical aside)")

(* ---- Positive cases (must trigger with the right signal) ----------- *)

let test_odd_fence_triggers () =
  check (option signal_t) "unclosed code fence"
    (Some Tool_board.Odd_fence)
    (detect "Here is code:\n```python\nprint('hello')")

let test_odd_inline_tick_triggers () =
  check (option signal_t) "trailing lone backtick"
    (Some Tool_board.Odd_inline_tick)
    (detect "Use the `read function")

let test_odd_double_asterisk_triggers () =
  check (option signal_t) "unclosed bold"
    (Some Tool_board.Odd_double_asterisk)
    (detect "This is **important and never closed")

let test_odd_double_asterisk_outside_inline_code_triggers () =
  check (option signal_t) "unclosed bold after inline glob"
    (Some Tool_board.Odd_double_asterisk)
    (detect "Run `ls **/*.ml`, then write **summary")

let test_unfinished_link_triggers () =
  check (option signal_t) "trailing [text]( with no )"
    (Some Tool_board.Unfinished_link)
    (detect "See the docs at [reference](https://example.com/path")

let test_unfinished_image_triggers () =
  check (option signal_t) "trailing ![alt]( with no )"
    (Some Tool_board.Unfinished_image)
    (detect "Diagram: ![overview](http://example.com/img.png")

(* ---- Priority order: fence wins over later signals ----------------- *)

let test_fence_priority_over_link () =
  (* Both an unclosed fence AND an unfinished link present — fence wins. *)
  let s = "```\ntext\nlink: [foo](http://x" in
  check (option signal_t) "fence has higher priority"
    (Some Tool_board.Odd_fence) (detect s)

(* ---- Boolean wrapper agrees with reason API ------------------------ *)

let test_bool_wrapper_agrees () =
  let cases = [
    ("complete.", false);
    ("```\nopen", true);
    ("trailing `code", true);
    ("trailing [link](url", true);
  ] in
  List.iter (fun (input, expected) ->
    check bool (Printf.sprintf "case %S" input) expected
      (Tool_board.detect_truncated_markdown input)
  ) cases

let () =
  run "board truncation detection (#9777)"
    [
      ( "negative",
        [
          test_case "complete text" `Quick test_complete_text_no_signal;
          test_case "balanced fence" `Quick test_balanced_fence_no_signal;
          test_case "balanced inline tick" `Quick test_balanced_inline_tick_no_signal;
          test_case "double asterisk in inline code" `Quick test_double_asterisk_in_inline_code_no_signal;
          test_case "underscore identifier" `Quick test_underscore_in_identifier_not_truncation;
          test_case "prose paren" `Quick test_paren_in_prose_not_unfinished_link;
        ] );
      ( "positive",
        [
          test_case "odd fence" `Quick test_odd_fence_triggers;
          test_case "odd inline tick" `Quick test_odd_inline_tick_triggers;
          test_case "odd double asterisk" `Quick test_odd_double_asterisk_triggers;
          test_case "odd double asterisk outside inline code" `Quick test_odd_double_asterisk_outside_inline_code_triggers;
          test_case "unfinished link" `Quick test_unfinished_link_triggers;
          test_case "unfinished image" `Quick test_unfinished_image_triggers;
        ] );
      ( "priority",
        [
          test_case "fence wins over link" `Quick test_fence_priority_over_link;
        ] );
      ( "compat",
        [
          test_case "bool wrapper agrees with reason" `Quick test_bool_wrapper_agrees;
        ] );
    ]
