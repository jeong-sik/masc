(* Tick 14: legacy ↔ shadow diff harness.

   These tests pin the diff taxonomy on a canonical corpus so the
   eventual flag flip (decision point 2 of the plan) can simply
   gate on a CI job that re-runs this harness against prod traces
   and asserts zero [Legacy_allow_shadow_deny] rows. *)

open Alcotest

module W = Masc_mcp.Worker_dev_tools

let diff_tag cmd =
  let d, _, _ = W.diff_command cmd in
  W.gate_diff_to_string d

let test_simple_ls_agrees () =
  check string "ls agree" "agree" (diff_tag "ls")

let test_rm_rf_agrees_on_deny () =
  (* Legacy: rm without both -r and -f bundled into single flag
     does not hit the structural short-circuit, but Eval_gate
     catches "rm -rf" substring, so legacy denies.
     Shadow: classify_destructive hits Recursive_delete.
     Diff: agree. *)
  check string "rm -rf agree on deny" "agree" (diff_tag "rm -rf /tmp/x")

let test_benign_disallowed_command_yields_agree () =
  (* `foo` is not in the allowlist; legacy rejects by allowlist,
     shadow parses "foo" as parsed_simple with no destructive hit.
     Per diff_of_verdicts, Legacy_reject_by_allowlist short-circuits
     to Agree so the harness does not flag every disallowed-but-safe
     command as a diff. *)
  check string "benign unknown bin → agree" "agree" (diff_tag "foo bar")

let test_pipeline_shadow_agrees_with_legacy_policy () =
  (* Pipeline parsing is now covered by the shadow parser. Legacy still
     owns allowlist policy, so a benign disallowed pipeline is [Agree],
     not a parser-coverage gap. *)
  let d, _, _ = W.diff_command "ls | wc -l" in
  check string "pipe agrees" "agree" (W.gate_diff_to_string d)

let test_sql_destructive_agrees () =
  (* `drop table foo` is denied by legacy (Eval_gate) and by shadow
     (Sql_destructive). *)
  check string "drop table agree" "agree" (diff_tag "drop table users")

let test_diff_command_returns_triple_shape () =
  let d, legacy, shadow = W.diff_command "ls" in
  (match d with W.Agree -> () | _ -> fail "ls should agree");
  (match legacy with
   | W.Legacy_allow -> ()
   | _ -> fail "ls is in legacy allowlist");
  (match shadow with
   | W.Shadow_allow { parse_tag = "parsed_simple" } -> ()
   | _ -> fail "ls shadow should be parsed_simple")

let test_destructive_class_surfaced_on_shadow_deny () =
  let _, _, shadow = W.diff_command "git push --force origin main" in
  match shadow with
  | W.Shadow_deny_destructive (cls, _) ->
      check string "forced_git_mutation" "forced_git_mutation"
        (W.destructive_class_to_string cls)
  | _ -> fail "expected Shadow_deny_destructive"

let test_all_eval_gate_patterns_are_agree_or_shadow_cannot_parse () =
  (* Critical covenant for the flip: no Eval_gate pattern may land
     in [Legacy_deny_shadow_allow].  Either the shadow denies too
     (Agree) or it cannot yet parse (Shadow_cannot_parse).  If a
     pattern slips into [Legacy_deny_shadow_allow], the flip would
     unblock real destructive commands. *)
  let patterns = Masc_mcp.Eval_gate.destructive_patterns in
  List.iter (fun (pat, desc) ->
    let d, _, _ = W.diff_command pat in
    match d with
    | W.Agree | W.Shadow_cannot_parse -> ()
    | W.Legacy_deny_shadow_allow ->
        fail (Printf.sprintf
                "flip blocker: %S (%s) is legacy_deny_shadow_allow"
                pat desc)
    | W.Legacy_allow_shadow_deny ->
        fail (Printf.sprintf
                "inverted gap: %S (%s) is legacy_allow_shadow_deny"
                pat desc))
    patterns

let () =
  run "gate_diff" [
    ("smoke", [
      test_case "simple ls agrees" `Quick test_simple_ls_agrees;
      test_case "rm -rf deny agree" `Quick test_rm_rf_agrees_on_deny;
      test_case "unknown bin still agree" `Quick
        test_benign_disallowed_command_yields_agree;
      test_case "sql destructive agree" `Quick test_sql_destructive_agrees;
      test_case "pipeline shadow agrees with legacy policy" `Quick
        test_pipeline_shadow_agrees_with_legacy_policy;
    ]);
    ("shape", [
      test_case "diff_command triple shape" `Quick
        test_diff_command_returns_triple_shape;
      test_case "shadow deny exposes class" `Quick
        test_destructive_class_surfaced_on_shadow_deny;
    ]);
    ("flip_covenant", [
      test_case "no eval_gate pattern is legacy_deny_shadow_allow" `Quick
        test_all_eval_gate_patterns_are_agree_or_shadow_cannot_parse;
    ]);
  ]
