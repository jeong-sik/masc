(* test/test_personality_text_equal.ml

   #10061: lock down the whitespace-insensitive compare used by
   [ensure_keeper_meta]'s [personality_changed] branch.  Byte-exact
   equality over state-JSON vs TOML-heredoc round-trip produced
   a re-sync storm on [nick0cave] (2880 redundant writes/day) from
   a single trailing newline drift.  [personality_text_equal]
   normalizes with [String.trim] so leading/trailing whitespace
   never triggers a semantic-change classification.

   The test pins three scenarios:
   1. The exact observed drift - state has one extra trailing
      newline vs target - now compares equal.
   2. Intra-string content differences - adding one word in the
      middle - still compare NOT equal (normalization must not
      swallow real changes).
   3. Identity, empty-string, and all-whitespace cases behave
      sensibly. *)

module KR = Masc_mcp.Keeper_runtime

let test_trailing_newline_drift_is_equal () =
  (* The exact shape from the #10061 evidence: state blob has one
     extra empty trailing line vs TOML. *)
  let state_blob = "You are nick0cave.\nSubstantive or skip.\n\n" in
  let toml_blob = "You are nick0cave.\nSubstantive or skip.\n" in
  Alcotest.(check bool)
    "trailing newline drift compares equal (stops re-sync storm)"
    true
    (KR.personality_text_equal state_blob toml_blob)
;;

let test_leading_whitespace_drift_is_equal () =
  let a = "  some instructions\n" in
  let b = "some instructions" in
  Alcotest.(check bool)
    "leading+trailing whitespace drift compares equal"
    true
    (KR.personality_text_equal a b)
;;

let test_intra_content_difference_is_not_equal () =
  (* Real semantic change must still trigger personality_changed. *)
  let a = "You are nick0cave.\nSubstantive or skip." in
  let b = "You are sangsu.\nSubstantive or skip." in
  Alcotest.(check bool)
    "intra-content change still NOT equal"
    false
    (KR.personality_text_equal a b)
;;

let test_empty_vs_whitespace_only_is_equal () =
  (* A state field that holds only whitespace (e.g. stale state
     carries "  \n") compared against a target that is empty
     (e.g. TOML field omitted).  Both trim to "" - equal. *)
  Alcotest.(check bool)
    "empty vs all-whitespace compares equal"
    true
    (KR.personality_text_equal "" "  \n\t\n")
;;

let test_identity_is_equal () =
  let s = "identical payload" in
  Alcotest.(check bool) "identity" true (KR.personality_text_equal s s)
;;

let () =
  Alcotest.run
    "personality_text_equal_10061"
    [ ( "whitespace_drift"
      , [ Alcotest.test_case
            "trailing newline drift -> equal"
            `Quick
            test_trailing_newline_drift_is_equal
        ; Alcotest.test_case
            "leading+trailing drift -> equal"
            `Quick
            test_leading_whitespace_drift_is_equal
        ; Alcotest.test_case
            "empty vs all-whitespace -> equal"
            `Quick
            test_empty_vs_whitespace_only_is_equal
        ; Alcotest.test_case "identity -> equal" `Quick test_identity_is_equal
        ] )
    ; ( "real_changes"
      , [ Alcotest.test_case
            "intra-content difference -> NOT equal"
            `Quick
            test_intra_content_difference_is_not_equal
        ] )
    ]
;;
