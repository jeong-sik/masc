(** #10269 — pin the personality re-sync diagnostic surface.

    Pre-#10269 the re-sync log line was opaque:
    [re-syncing [personality] for nick0cave].  371 such events
    accumulated on a single keeper in 3000 logs (12% of all log
    volume) without surfacing WHICH personality field diverged or by
    HOW MUCH.  Operators couldn't tell whether the drift was a
    1-byte trailing-newline mismatch (already covered by
    [personality_text_equal] from #10061) or a structural divergence
    between TOML source and persisted JSON.

    These tests pin the contract of {!Keeper_runtime.personality_diff_summary}:

    1. Empty input list -> empty summary.
    2. Equal-after-trim fields produce no entries (matches the
       semantics of {!personality_text_equal}).
    3. Differing fields produce entries naming the field, both
       trimmed lengths, and the byte index of the first divergence.
    4. The first-diff offset is computed AFTER trimming so trailing
       whitespace drift never reports a position artefact.
    5. When two fields differ, the summary preserves their input
       order (so the log line is stable across runs). *)

open Alcotest
module KR = Masc_mcp.Keeper_runtime

(* --- empty / no-diff cases -------------------------------------- *)

let test_empty_list_yields_empty_summary () =
  check (list string) "empty input -> empty summary" [] (KR.personality_diff_summary [])
;;

let test_equal_fields_emit_no_entries () =
  let same = "You are nick0cave.\nSubstantive or skip." in
  check
    (list string)
    "byte-equal fields produce no entries"
    []
    (KR.personality_diff_summary [ "goal", same, same ])
;;

let test_trim_equivalent_fields_emit_no_entries () =
  (* Same shape as the #10061 trailing-newline drift. *)
  let cur = "You are nick0cave.\nSubstantive or skip.\n\n" in
  let tgt = "You are nick0cave.\nSubstantive or skip.\n" in
  check
    (list string)
    "trim-equivalent fields produce no entries"
    []
    (KR.personality_diff_summary [ "goal", cur, tgt ])
;;

(* --- diff cases ------------------------------------------------- *)

let test_single_field_diff_names_field_and_lengths () =
  let cur = "short" in
  (* trimmed length 5 *)
  let tgt = "different" in
  (* trimmed length 9 *)
  match KR.personality_diff_summary [ "instructions", cur, tgt ] with
  | [ entry ] ->
    check
      string
      "names instructions, lengths 5 vs 9, diff @ 0"
      "instructions(cur=5,tgt=9,diff@0)"
      entry
  | other ->
    failf
      "expected exactly 1 entry, got %d: [%s]"
      (List.length other)
      (String.concat ";" other)
;;

let test_first_diff_offset_after_common_prefix () =
  let cur = "You are nick0cave." in
  (* 18 chars *)
  let tgt = "You are sangsu." in
  (* 15 chars; differs at byte 8 *)
  match KR.personality_diff_summary [ "goal", cur, tgt ] with
  | [ entry ] ->
    check string "diff @ 8 (after 'You are ')" "goal(cur=18,tgt=15,diff@8)" entry
  | other ->
    failf
      "expected exactly 1 entry, got %d: [%s]"
      (List.length other)
      (String.concat ";" other)
;;

let test_one_string_is_prefix_of_other_reports_shorter_length () =
  (* Common prefix exhausted, then [target] has more bytes.
     [diff] offset becomes [min len_a len_b] = the shorter length. *)
  let cur = "You are nick0cave." in
  (* 18 chars *)
  let tgt = "You are nick0cave. Be sharp." in
  (* 28 chars *)
  match KR.personality_diff_summary [ "goal", cur, tgt ] with
  | [ entry ] -> check string "prefix case: diff @ 18" "goal(cur=18,tgt=28,diff@18)" entry
  | other ->
    failf
      "expected exactly 1 entry, got %d: [%s]"
      (List.length other)
      (String.concat ";" other)
;;

(* --- order-preservation across multiple fields ------------------- *)

let test_multiple_diff_fields_preserve_input_order () =
  let same = "X" in
  let entries =
    KR.personality_diff_summary
      [ "goal", same, same
      ; (* equal: skipped *)
        "short_goal", "abc", "abd"
      ; (* differs at 2 *)
        "mid_goal", same, same
      ; (* equal: skipped *)
        "instructions", "longer", "longish" (* differs at 4 *)
      ]
  in
  check
    (list string)
    "stable order, equal fields filtered"
    [ "short_goal(cur=3,tgt=3,diff@2)"; "instructions(cur=6,tgt=7,diff@4)" ]
    entries
;;

(* --- offset is computed AFTER trim ------------------------------ *)

let test_first_diff_offset_uses_trimmed_strings () =
  (* Without trim, the leading newlines on [cur] would shift the
     diff offset to a misleading position.  After trim, both sides
     start at byte 0 with character ['Y']. *)
  let cur = "\n\n  You are nick0cave." in
  (* trims to "You are nick0cave." len 18 *)
  let tgt = "You are sangsu." in
  (* len 15; diff @ 8 *)
  match KR.personality_diff_summary [ "goal", cur, tgt ] with
  | [ entry ] ->
    check string "trim runs before offset computation" "goal(cur=18,tgt=15,diff@8)" entry
  | other ->
    failf
      "expected exactly 1 entry, got %d: [%s]"
      (List.length other)
      (String.concat ";" other)
;;

let () =
  run
    "personality_diff_summary_10269"
    [ ( "no-diff"
      , [ test_case
            "empty input -> empty summary"
            `Quick
            test_empty_list_yields_empty_summary
        ; test_case "byte-equal fields skipped" `Quick test_equal_fields_emit_no_entries
        ; test_case
            "trim-equivalent fields skipped"
            `Quick
            test_trim_equivalent_fields_emit_no_entries
        ] )
    ; ( "diff"
      , [ test_case
            "single field names lengths + diff @ 0"
            `Quick
            test_single_field_diff_names_field_and_lengths
        ; test_case
            "diff @ offset after common prefix"
            `Quick
            test_first_diff_offset_after_common_prefix
        ; test_case
            "prefix case reports shorter length"
            `Quick
            test_one_string_is_prefix_of_other_reports_shorter_length
        ] )
    ; ( "ordering"
      , [ test_case
            "multiple diffs preserve input order"
            `Quick
            test_multiple_diff_fields_preserve_input_order
        ] )
    ; ( "trim-before-offset"
      , [ test_case
            "offset computed against trimmed strings"
            `Quick
            test_first_diff_offset_uses_trimmed_strings
        ] )
    ]
;;
