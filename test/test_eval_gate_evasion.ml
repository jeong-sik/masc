(** Tests for destructive pattern detection evasion resistance.

    Documents both caught evasions (normalization handles) and
    known gaps (require shell AST parsing to catch).

    Pure synchronous tests — no Eio or network required. *)

module Eval_gate = Masc_mcp.Eval_gate

(* ============================================================
   Normalization tests
   ============================================================ *)

let test_normalize_strips_single_quotes () =
  let n = Eval_gate.normalize_command "'r''m' '-rf' /tmp" in
  Alcotest.(check string) "quotes stripped" "rm -rf /tmp" n
;;

let test_normalize_strips_double_quotes () =
  let n = Eval_gate.normalize_command {|r"m" -r"f" /tmp|} in
  Alcotest.(check string) "double quotes stripped" "rm -rf /tmp" n
;;

let test_normalize_collapses_whitespace () =
  let n = Eval_gate.normalize_command "rm   -rf   /tmp" in
  Alcotest.(check string) "whitespace collapsed" "rm -rf /tmp" n
;;

let test_normalize_strips_tabs_newlines () =
  let n = Eval_gate.normalize_command "rm\t-rf\n/tmp" in
  Alcotest.(check string) "tabs/newlines normalized" "rm -rf /tmp" n
;;

let test_normalize_strips_backslash () =
  let n = Eval_gate.normalize_command "r\\m -rf /tmp" in
  Alcotest.(check string) "backslash stripped" "rm -rf /tmp" n
;;

let test_normalize_mixed () =
  let n = Eval_gate.normalize_command {|'g''i''t'  "push"  --force|} in
  Alcotest.(check string) "mixed evasion normalized" "git push --force" n
;;

(* ============================================================
   Caught evasions (normalization handles these)
   ============================================================ *)

let test_catches_quoted_rm () =
  match Eval_gate.detect_destructive "'rm' '-rf' /data" with
  | Some (_, desc) ->
    Alcotest.(check string) "caught quoted rm" "recursive forced deletion" desc
  | None -> Alcotest.fail "Should catch quoted rm -rf"
;;

let test_catches_double_quoted_rm () =
  match Eval_gate.detect_destructive {|"rm" "-rf" /data|} with
  | Some _ -> ()
  | None -> Alcotest.fail "Should catch double-quoted rm -rf"
;;

let test_catches_extra_whitespace () =
  match Eval_gate.detect_destructive "rm    -rf    /data" with
  | Some _ -> ()
  | None -> Alcotest.fail "Should catch rm with extra whitespace"
;;

let test_catches_tabbed_rm () =
  match Eval_gate.detect_destructive "rm\t-rf\t/data" with
  | Some _ -> ()
  | None -> Alcotest.fail "Should catch rm with tabs"
;;

let test_catches_backslash_rm () =
  match Eval_gate.detect_destructive "r\\m -rf /data" with
  | Some _ -> ()
  | None -> Alcotest.fail "Should catch backslash-escaped rm"
;;

let test_catches_quoted_git_push () =
  match Eval_gate.detect_destructive "'git' 'push' '--force'" with
  | Some (_, desc) -> Alcotest.(check string) "caught quoted git push" "force push" desc
  | None -> Alcotest.fail "Should catch quoted git push --force"
;;

let test_catches_quoted_drop_table () =
  match Eval_gate.detect_destructive "'drop' 'table' users" with
  | Some (_, desc) -> Alcotest.(check string) "caught quoted drop" "SQL table drop" desc
  | None -> Alcotest.fail "Should catch quoted DROP TABLE"
;;

let test_catches_newline_separated () =
  match Eval_gate.detect_destructive "git push\n--force origin" with
  | Some _ -> ()
  | None -> Alcotest.fail "Should catch newline-separated force push"
;;

(* ============================================================
   Former known gaps — now detected after A-7 evasion hardening.
   These patterns used to bypass detection but are now caught.
   ============================================================ *)

let test_gap_variable_expansion () =
  (* ${IFS} expands to space in bash, so rm${IFS}-rf becomes rm -rf *)
  let result = Eval_gate.detect_destructive "rm${IFS}-rf /data" in
  Alcotest.(check bool) "variable expansion now detected" true (Option.is_some result)
;;

let test_gap_command_substitution () =
  (* $(echo rm) -rf expands to rm -rf in bash *)
  let result = Eval_gate.detect_destructive "$(echo rm) -rf /data" in
  Alcotest.(check bool) "command substitution now detected" true (Option.is_some result)
;;

let test_gap_hex_escape () =
  (* $'\x72\x6d' expands to rm in bash *)
  let result = Eval_gate.detect_destructive "$'\\x72\\x6d' -rf /data" in
  Alcotest.(check bool) "hex escape now detected" true (Option.is_some result)
;;

let test_gap_base64_decode () =
  (* echo cm0gLXJm | base64 -d | sh → executes rm -rf *)
  let result = Eval_gate.detect_destructive "echo cm0gLXJm | base64 -d | sh" in
  Alcotest.(check bool) "base64 pipe now detected" true (Option.is_some result)
;;

(* ============================================================
   Safe commands still pass
   ============================================================ *)

let test_safe_echo () =
  match Eval_gate.detect_destructive "echo 'hello world'" with
  | Some _ -> Alcotest.fail "Safe echo should not trigger"
  | None -> ()
;;

let test_safe_grep () =
  match Eval_gate.detect_destructive "grep -r 'pattern' /src" with
  | None -> ()
  | Some _ -> Alcotest.fail "grep should be safe"
;;

let test_safe_git_push () =
  match Eval_gate.detect_destructive "git push origin main" with
  | None -> ()
  | Some _ -> Alcotest.fail "normal git push should be safe"
;;

(* ============================================================
   Known false positives (conservative — safe in practice)
   Normalization strips quoting context, so safe string arguments
   containing destructive patterns will trigger detection.
   This is acceptable for a defense-in-depth layer.
   ============================================================ *)

let test_false_positive_echo_pattern () =
  (* echo 'rm -rf ...' is safe in bash, but normalization strips quotes *)
  let result = Eval_gate.detect_destructive "echo 'rm -rf is dangerous'" in
  Alcotest.(check bool)
    "echo with pattern triggers (false positive, conservative)"
    true
    (result <> None)
;;

let test_false_positive_nested_quotes () =
  (* Nested quotes: outer double-quote preserves inner single-quote as literal *)
  let result = Eval_gate.detect_destructive {|psql -c "'drop' 'table' users"|} in
  (* Inner quotes are preserved when inside outer quotes — pattern not found *)
  Alcotest.(check bool) "nested quotes bypass (known false negative)" true (result = None)
;;

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run
    "Eval_gate_evasion"
    [ ( "normalization"
      , [ Alcotest.test_case
            "strip single quotes"
            `Quick
            test_normalize_strips_single_quotes
        ; Alcotest.test_case
            "strip double quotes"
            `Quick
            test_normalize_strips_double_quotes
        ; Alcotest.test_case
            "collapse whitespace"
            `Quick
            test_normalize_collapses_whitespace
        ; Alcotest.test_case
            "strip tabs/newlines"
            `Quick
            test_normalize_strips_tabs_newlines
        ; Alcotest.test_case "strip backslash" `Quick test_normalize_strips_backslash
        ; Alcotest.test_case "mixed evasion" `Quick test_normalize_mixed
        ] )
    ; ( "caught_evasions"
      , [ Alcotest.test_case "quoted rm" `Quick test_catches_quoted_rm
        ; Alcotest.test_case "double-quoted rm" `Quick test_catches_double_quoted_rm
        ; Alcotest.test_case "extra whitespace" `Quick test_catches_extra_whitespace
        ; Alcotest.test_case "tabbed rm" `Quick test_catches_tabbed_rm
        ; Alcotest.test_case "backslash rm" `Quick test_catches_backslash_rm
        ; Alcotest.test_case "quoted git push" `Quick test_catches_quoted_git_push
        ; Alcotest.test_case "quoted drop table" `Quick test_catches_quoted_drop_table
        ; Alcotest.test_case "newline separated" `Quick test_catches_newline_separated
        ] )
    ; ( "known_gaps"
      , [ Alcotest.test_case "variable expansion" `Quick test_gap_variable_expansion
        ; Alcotest.test_case "command substitution" `Quick test_gap_command_substitution
        ; Alcotest.test_case "hex escape" `Quick test_gap_hex_escape
        ; Alcotest.test_case "base64 decode" `Quick test_gap_base64_decode
        ] )
    ; ( "false_positives"
      , [ Alcotest.test_case "echo with pattern" `Quick test_false_positive_echo_pattern
        ; Alcotest.test_case
            "nested quotes bypass"
            `Quick
            test_false_positive_nested_quotes
        ] )
    ; ( "safe_commands"
      , [ Alcotest.test_case "echo safe" `Quick test_safe_echo
        ; Alcotest.test_case "grep" `Quick test_safe_grep
        ; Alcotest.test_case "normal git push" `Quick test_safe_git_push
        ] )
    ]
;;
