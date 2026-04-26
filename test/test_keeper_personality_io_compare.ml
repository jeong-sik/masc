(** Tests for [Keeper_personality_io.compare_normalized] — samchon
    harness commit 4. Replacement for the Layer 1
    [Keeper_runtime.personality_text_equal / _diff_summary] family. *)

open Alcotest
open Masc_mcp

let make ?(will = "") ?(needs = "") ?(desires = "") ?(instructions = "") () :
    Keeper_personality_io.raw_personality =
  { will; needs; desires; instructions }

let coerce p = Keeper_personality_io.coerce p

let drift_fields = function
  | `Equal -> []
  | `Drift diffs ->
      List.map
        (fun (d : Keeper_personality_io.field_diff) ->
          Keeper_personality_io.field_to_string d.field)
        diffs

let assert_equal ~label a b =
  match Keeper_personality_io.compare_normalized (coerce a) (coerce b) with
  | `Equal -> ()
  | `Drift _ -> fail (Printf.sprintf "%s: expected Equal, got Drift" label)

let assert_drift ~label ~expected_fields a b =
  match Keeper_personality_io.compare_normalized (coerce a) (coerce b) with
  | `Equal -> fail (Printf.sprintf "%s: expected Drift, got Equal" label)
  | `Drift diffs ->
      let got =
        List.map
          (fun (d : Keeper_personality_io.field_diff) ->
            Keeper_personality_io.field_to_string d.field)
          diffs
      in
      check (list string) label expected_fields got

(* --------------------------------------------------------------------- *)
(* Equal: trim differences swallowed                                     *)
(* --------------------------------------------------------------------- *)

let test_identical_inputs_equal () =
  let p = make ~will:"a" ~needs:"b" ~desires:"c" ~instructions:"d" () in
  assert_equal ~label:"identical" p p

let test_trailing_whitespace_equal () =
  let a = make ~will:"hello" () in
  let b = make ~will:"hello   " () in
  assert_equal ~label:"trailing whitespace" a b

let test_leading_newline_equal () =
  let a = make ~needs:"alpha" () in
  let b = make ~needs:"\n\nalpha" () in
  assert_equal ~label:"leading newlines" a b

let test_only_whitespace_vs_empty_equal () =
  let a = make ~desires:"" () in
  let b = make ~desires:"   \n\t" () in
  assert_equal ~label:"only-whitespace vs empty" a b

(* --------------------------------------------------------------------- *)
(* Drift: real content differences                                       *)
(* --------------------------------------------------------------------- *)

let test_single_field_drift () =
  let a = make ~will:"alpha" () in
  let b = make ~will:"beta" () in
  assert_drift ~label:"single field" ~expected_fields:[ "will" ] a b

let test_multiple_field_drift_canonical_order () =
  let a = make ~will:"a" ~desires:"d" () in
  let b = make ~will:"b" ~desires:"e" () in
  assert_drift ~label:"two fields" ~expected_fields:[ "will"; "desires" ] a b

let test_all_fields_drift () =
  let a =
    make ~will:"a1" ~needs:"n1" ~desires:"d1" ~instructions:"i1" ()
  in
  let b =
    make ~will:"a2" ~needs:"n2" ~desires:"d2" ~instructions:"i2" ()
  in
  assert_drift ~label:"all four fields"
    ~expected_fields:[ "will"; "needs"; "desires"; "instructions" ] a b

(* --------------------------------------------------------------------- *)
(* Diff details: byte counts + offset                                    *)
(* --------------------------------------------------------------------- *)

let test_diff_offset_matches_first_byte () =
  let a = make ~will:"abcXYZ" () in
  let b = make ~will:"abcDEF" () in
  match Keeper_personality_io.compare_normalized (coerce a) (coerce b) with
  | `Equal -> fail "expected Drift"
  | `Drift [ d ] ->
      check int "diff_offset is index of first differing byte" 3 d.diff_offset;
      check int "current_bytes" 6 d.current_bytes;
      check int "target_bytes" 6 d.target_bytes
  | `Drift _ -> fail "expected exactly 1 diff"

let test_prefix_relation_offset_at_shorter_length () =
  let a = make ~will:"abc" () in
  let b = make ~will:"abcdef" () in
  match Keeper_personality_io.compare_normalized (coerce a) (coerce b) with
  | `Drift [ d ] ->
      check int "offset = shorter length" 3 d.diff_offset;
      check int "current_bytes" 3 d.current_bytes;
      check int "target_bytes" 6 d.target_bytes
  | _ -> fail "expected exactly 1 diff"

(* --------------------------------------------------------------------- *)
(* Layer 1 regression: nick0cave 357-byte will, asymmetric raw vs trim  *)
(* --------------------------------------------------------------------- *)

let test_oversized_with_trailing_newline_still_equal () =
  (* The exact pattern that caused the original drift loop:
     write path stored "will\n" (raw) while read path normalised
     to "will" (no newline). After Layer 1 + this harness both go
     through coerce, so they compare Equal. *)
  let nick0cave = String.make 357 'a' in
  let a = make ~will:nick0cave () in
  let b = make ~will:(nick0cave ^ "\n") () in
  assert_equal ~label:"nick0cave 357B with trailing newline" a b

let () =
  run "keeper_personality_io_compare"
    [
      ( "Equal: trim swallows whitespace",
        [
          test_case "identical inputs" `Quick test_identical_inputs_equal;
          test_case "trailing whitespace" `Quick test_trailing_whitespace_equal;
          test_case "leading newlines" `Quick test_leading_newline_equal;
          test_case "only-whitespace vs empty" `Quick
            test_only_whitespace_vs_empty_equal;
        ] );
      ( "Drift: real content differences",
        [
          test_case "single field" `Quick test_single_field_drift;
          test_case "two fields in canonical order" `Quick
            test_multiple_field_drift_canonical_order;
          test_case "all four fields" `Quick test_all_fields_drift;
        ] );
      ( "Diff details",
        [
          test_case "diff_offset is index of first differing byte" `Quick
            test_diff_offset_matches_first_byte;
          test_case "prefix relation: offset at shorter length" `Quick
            test_prefix_relation_offset_at_shorter_length;
        ] );
      ( "Layer 1 regression",
        [
          test_case "nick0cave 357B + trailing newline → Equal" `Quick
            test_oversized_with_trailing_newline_still_equal;
        ] );
    ]
