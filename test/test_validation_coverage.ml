(** Validation Module Coverage Tests

    Tests for MASC Input Validation - Security Module:
    - Agent_id: alphanumeric, dash, underscore validation
    - Task_id: alphanumeric, dash, underscore, colon validation
    - Path traversal prevention
    - Length validation
    - Rejection statistics
*)

open Alcotest

module Validation = Validation

(* ============================================================
   Agent_id Tests
   ============================================================ *)

let test_agent_id_valid_simple () =
  match Validation.Agent_id.validate "claude" with
  | Ok t -> check string "to_string" "claude" (Validation.Agent_id.to_string t)
  | Error e -> fail e

let test_agent_id_valid_with_dash () =
  match Validation.Agent_id.validate "claude-opus" with
  | Ok t -> check string "to_string" "claude-opus" (Validation.Agent_id.to_string t)
  | Error e -> fail e

let test_agent_id_valid_with_underscore () =
  match Validation.Agent_id.validate "agent_001" with
  | Ok t -> check string "to_string" "agent_001" (Validation.Agent_id.to_string t)
  | Error e -> fail e

let test_agent_id_valid_numeric () =
  match Validation.Agent_id.validate "12345" with
  | Ok t -> check string "numeric ok" "12345" (Validation.Agent_id.to_string t)
  | Error e -> fail e

let test_agent_id_valid_mixed () =
  match Validation.Agent_id.validate "Agent-X_42" with
  | Ok t -> check string "mixed" "Agent-X_42" (Validation.Agent_id.to_string t)
  | Error e -> fail e

let test_agent_id_valid_colon_namespace () =
  match Validation.Agent_id.validate "keeper:keeper-test-98295-0" with
  | Ok t -> check string "colon namespace" "keeper:keeper-test-98295-0" (Validation.Agent_id.to_string t)
  | Error e -> fail e

let test_agent_id_reject_empty () =
  match Validation.Agent_id.validate "" with
  | Ok _ -> fail "should reject empty"
  | Error e -> check bool "contains empty" true (String.length e > 0)

let test_agent_id_reject_too_long () =
  let long_id = String.make 100 'a' in
  match Validation.Agent_id.validate long_id with
  | Ok _ -> fail "should reject too long"
  | Error e -> check bool "contains long" true (String.length e > 0)

let test_agent_id_reject_slash () =
  match Validation.Agent_id.validate "agent/bad" with
  | Ok _ -> fail "should reject slash"
  | Error e -> check bool "contains path" true (String.length e > 0)

let test_agent_id_reject_backslash () =
  match Validation.Agent_id.validate "agent\\bad" with
  | Ok _ -> fail "should reject backslash"
  | Error e -> check bool "contains path" true (String.length e > 0)

let test_agent_id_reject_path_traversal () =
  match Validation.Agent_id.validate "../etc/passwd" with
  | Ok _ -> fail "should reject path traversal"
  | Error e -> check bool "contains traversal" true (String.length e > 0)

let test_agent_id_reject_special_chars () =
  match Validation.Agent_id.validate "agent@domain.com" with
  | Ok _ -> fail "should reject special chars"
  | Error e -> check bool "contains invalid" true (String.length e > 0)

let test_agent_id_reject_space () =
  match Validation.Agent_id.validate "agent name" with
  | Ok _ -> fail "should reject space"
  | Error e -> check bool "error exists" true (String.length e > 0)

let test_agent_id_reject_bare_colon () =
  match Validation.Agent_id.validate ":" with
  | Ok _ -> fail "should reject bare colon"
  | Error _ -> ()

let test_agent_id_reject_multi_colon () =
  match Validation.Agent_id.validate "a:b:c" with
  | Ok _ -> fail "should reject multiple colons"
  | Error _ -> ()

let test_agent_id_reject_leading_colon () =
  match Validation.Agent_id.validate ":foo" with
  | Ok _ -> fail "should reject leading colon"
  | Error _ -> ()

let test_agent_id_reject_trailing_colon () =
  match Validation.Agent_id.validate "foo:" with
  | Ok _ -> fail "should reject trailing colon"
  | Error _ -> ()

let test_agent_id_of_string_unsafe () =
  let t = Validation.Agent_id.of_string_unsafe "unsafe-input" in
  check string "unsafe" "unsafe-input" (Validation.Agent_id.to_string t)

(* ============================================================
   Task_id Tests
   ============================================================ *)

let test_task_id_valid_simple () =
  match Validation.Task_id.validate "task-001" with
  | Ok t -> check string "to_string" "task-001" (Validation.Task_id.to_string t)
  | Error e -> fail e

let test_task_id_valid_with_colon () =
  match Validation.Task_id.validate "ns:task:123" with
  | Ok t -> check string "with colon" "ns:task:123" (Validation.Task_id.to_string t)
  | Error e -> fail e

let test_task_id_valid_mixed () =
  match Validation.Task_id.validate "Task_X-42:subid" with
  | Ok t -> check string "mixed" "Task_X-42:subid" (Validation.Task_id.to_string t)
  | Error e -> fail e

let test_task_id_reject_empty () =
  match Validation.Task_id.validate "" with
  | Ok _ -> fail "should reject empty"
  | Error e -> check bool "error exists" true (String.length e > 0)

let test_task_id_reject_too_long () =
  let long_id = String.make 200 'a' in
  match Validation.Task_id.validate long_id with
  | Ok _ -> fail "should reject too long"
  | Error e -> check bool "error exists" true (String.length e > 0)

let test_task_id_reject_slash () =
  match Validation.Task_id.validate "task/sub" with
  | Ok _ -> fail "should reject slash"
  | Error e -> check bool "error exists" true (String.length e > 0)

let test_task_id_reject_path_traversal () =
  match Validation.Task_id.validate "../../etc" with
  | Ok _ -> fail "should reject path traversal"
  | Error e -> check bool "error exists" true (String.length e > 0)

let test_task_id_reject_special_chars () =
  match Validation.Task_id.validate "task<script>" with
  | Ok _ -> fail "should reject special chars"
  | Error e -> check bool "error exists" true (String.length e > 0)

let test_task_id_of_string_unsafe () =
  let t = Validation.Task_id.of_string_unsafe "unsafe-task" in
  check string "unsafe" "unsafe-task" (Validation.Task_id.to_string t)

(* ============================================================
   Rejection Statistics Tests
   ============================================================ *)

let test_reset_rejection_stats () =
  Validation.reset_rejection_stats ();
  let (count, _) = Validation.get_rejection_stats () in
  check int "reset count" 0 count

let test_rejection_stats_increment () =
  Validation.reset_rejection_stats ();
  (* Trigger exactly 2 rejections *)
  ignore (Validation.Agent_id.validate "");
  ignore (Validation.Agent_id.validate "bad/path");
  let (count, time) = Validation.get_rejection_stats () in
  check int "exactly 2 rejections" 2 count;
  check bool "time > 0" true (time > 0.0)

(* ============================================================
   Edge Cases
   ============================================================ *)

let test_agent_id_max_length () =
  let max_id = String.make 64 'a' in
  match Validation.Agent_id.validate max_id with
  | Ok t -> check int "length 64" 64 (String.length (Validation.Agent_id.to_string t))
  | Error e -> fail e

let test_agent_id_over_max_length () =
  let over_id = String.make 65 'a' in
  match Validation.Agent_id.validate over_id with
  | Ok _ -> fail "should reject 65 chars"
  | Error _ -> ()

let test_task_id_max_length () =
  let max_id = String.make 128 'a' in
  match Validation.Task_id.validate max_id with
  | Ok t -> check int "length 128" 128 (String.length (Validation.Task_id.to_string t))
  | Error e -> fail e

let test_task_id_over_max_length () =
  let over_id = String.make 129 'a' in
  match Validation.Task_id.validate over_id with
  | Ok _ -> fail "should reject 129 chars"
  | Error _ -> ()

let test_agent_id_single_char () =
  match Validation.Agent_id.validate "a" with
  | Ok t -> check string "single char" "a" (Validation.Agent_id.to_string t)
  | Error e -> fail e

let test_task_id_single_char () =
  match Validation.Task_id.validate "X" with
  | Ok t -> check string "single char" "X" (Validation.Task_id.to_string t)
  | Error e -> fail e

let test_agent_id_unicode_rejected () =
  match Validation.Agent_id.validate "agent_한글" with
  | Ok _ -> fail "should reject unicode"
  | Error _ -> ()

let test_task_id_unicode_rejected () =
  match Validation.Task_id.validate "task_日本語" with
  | Ok _ -> fail "should reject unicode"
  | Error _ -> ()

let test_agent_id_dot_only () =
  match Validation.Agent_id.validate "agent.name" with
  | Ok _ -> fail "should reject dot"
  | Error _ -> ()

let test_agent_id_single_dot () =
  match Validation.Agent_id.validate "." with
  | Ok _ -> fail "should reject single dot"
  | Error _ -> ()

let test_agent_id_double_dot () =
  match Validation.Agent_id.validate ".." with
  | Ok _ -> fail "should reject double dot"
  | Error _ -> ()

(* ============================================================
   Sound-partial quote stripping (#9787)
   ============================================================ *)

let test_task_id_single_quoted_recoverable () =
  match Validation.Task_id.validate "'task-031'" with
  | Ok t -> check string "stripped to inner" "task-031" (Validation.Task_id.to_string t)
  | Error msg -> failf "expected recovery, got: %s" msg

let test_task_id_double_quoted_recoverable () =
  match Validation.Task_id.validate "\"task-041\"" with
  | Ok t -> check string "stripped to inner" "task-041" (Validation.Task_id.to_string t)
  | Error msg -> failf "expected recovery, got: %s" msg

let test_task_id_quoted_inner_invalid () =
  (* Outer quotes match but inner contains invalid char — must surface a
     quote-aware error and not silently accept the inner. *)
  match Validation.Task_id.validate "'bad/id'" with
  | Ok _ -> fail "should reject quoted but invalid inner"
  | Error msg ->
      check bool "mentions quotes" true
        (try ignore (Re.exec (Re.Pcre.re "quotes" |> Re.compile) msg); true
         with Not_found -> false)

let test_task_id_mismatched_quotes_not_stripped () =
  (* Single + double mismatch must NOT be stripped — keep strict error. *)
  match Validation.Task_id.validate "'task-031\"" with
  | Ok _ -> fail "should reject mismatched outer quotes"
  | Error _ -> ()

let test_task_id_unquoted_still_works () =
  match Validation.Task_id.validate "task-099" with
  | Ok t -> check string "preserved" "task-099" (Validation.Task_id.to_string t)
  | Error msg -> failf "should accept bare id: %s" msg

let test_agent_id_single_quoted_recoverable () =
  match Validation.Agent_id.validate "'keeper'" with
  | Ok t -> check string "stripped to inner" "keeper" (Validation.Agent_id.to_string t)
  | Error msg -> failf "expected recovery, got: %s" msg

let test_agent_id_quoted_inner_invalid () =
  match Validation.Agent_id.validate "'has space'" with
  | Ok _ -> fail "should reject quoted but invalid inner"
  | Error msg ->
      check bool "mentions quotes" true
        (try ignore (Re.exec (Re.Pcre.re "quotes" |> Re.compile) msg); true
         with Not_found -> false)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Validation Coverage" [
    "agent_id.valid", [
      test_case "simple" `Quick test_agent_id_valid_simple;
      test_case "with dash" `Quick test_agent_id_valid_with_dash;
      test_case "with underscore" `Quick test_agent_id_valid_with_underscore;
      test_case "numeric" `Quick test_agent_id_valid_numeric;
      test_case "mixed" `Quick test_agent_id_valid_mixed;
      test_case "colon namespace" `Quick test_agent_id_valid_colon_namespace;
    ];
    "agent_id.reject", [
      test_case "empty" `Quick test_agent_id_reject_empty;
      test_case "too long" `Quick test_agent_id_reject_too_long;
      test_case "slash" `Quick test_agent_id_reject_slash;
      test_case "backslash" `Quick test_agent_id_reject_backslash;
      test_case "path traversal" `Quick test_agent_id_reject_path_traversal;
      test_case "special chars" `Quick test_agent_id_reject_special_chars;
      test_case "space" `Quick test_agent_id_reject_space;
      test_case "bare colon" `Quick test_agent_id_reject_bare_colon;
      test_case "multi colon" `Quick test_agent_id_reject_multi_colon;
      test_case "leading colon" `Quick test_agent_id_reject_leading_colon;
      test_case "trailing colon" `Quick test_agent_id_reject_trailing_colon;
    ];
    "agent_id.unsafe", [
      test_case "of_string_unsafe" `Quick test_agent_id_of_string_unsafe;
    ];
    "task_id.valid", [
      test_case "simple" `Quick test_task_id_valid_simple;
      test_case "with colon" `Quick test_task_id_valid_with_colon;
      test_case "mixed" `Quick test_task_id_valid_mixed;
    ];
    "task_id.reject", [
      test_case "empty" `Quick test_task_id_reject_empty;
      test_case "too long" `Quick test_task_id_reject_too_long;
      test_case "slash" `Quick test_task_id_reject_slash;
      test_case "path traversal" `Quick test_task_id_reject_path_traversal;
      test_case "special chars" `Quick test_task_id_reject_special_chars;
    ];
    "task_id.unsafe", [
      test_case "of_string_unsafe" `Quick test_task_id_of_string_unsafe;
    ];
    "rejection_stats", [
      test_case "reset" `Quick test_reset_rejection_stats;
      test_case "increment" `Quick test_rejection_stats_increment;
    ];
    "edge_cases", [
      test_case "agent max length" `Quick test_agent_id_max_length;
      test_case "agent over max" `Quick test_agent_id_over_max_length;
      test_case "task max length" `Quick test_task_id_max_length;
      test_case "task over max" `Quick test_task_id_over_max_length;
      test_case "agent single char" `Quick test_agent_id_single_char;
      test_case "task single char" `Quick test_task_id_single_char;
      test_case "agent unicode rejected" `Quick test_agent_id_unicode_rejected;
      test_case "task unicode rejected" `Quick test_task_id_unicode_rejected;
      test_case "agent dot only" `Quick test_agent_id_dot_only;
      test_case "agent single dot" `Quick test_agent_id_single_dot;
      test_case "agent double dot" `Quick test_agent_id_double_dot;
    ];
    "quote_stripping_9787", [
      test_case "task single-quoted recoverable" `Quick test_task_id_single_quoted_recoverable;
      test_case "task double-quoted recoverable" `Quick test_task_id_double_quoted_recoverable;
      test_case "task quoted inner invalid" `Quick test_task_id_quoted_inner_invalid;
      test_case "task mismatched quotes" `Quick test_task_id_mismatched_quotes_not_stripped;
      test_case "task unquoted still works" `Quick test_task_id_unquoted_still_works;
      test_case "agent single-quoted recoverable" `Quick test_agent_id_single_quoted_recoverable;
      test_case "agent quoted inner invalid" `Quick test_agent_id_quoted_inner_invalid;
    ];
  ]
