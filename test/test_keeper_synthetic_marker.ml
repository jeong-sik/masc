(** test_keeper_synthetic_marker — SSOT for the [SYNTHETIC] marker.

    Pre-fix the literal ["[SYNTHETIC]"] was hardcoded in three files
    (keeper_memory_policy producer, keeper_memory_bank +
    keeper_exec_memory consumers).  This test pins the SSOT contract so
    a marker rename or accidental case-shift cannot silently break the
    producer-consumer detection pair. *)

open Masc_mcp

let r = Alcotest.(check string)
let b = Alcotest.(check bool)

let test_marker_prefix_value () =
  r "marker_prefix is the literal" "[SYNTHETIC]"
    Keeper_synthetic_marker.marker_prefix

let test_tag_prepends_with_space () =
  r "tag prepends marker + single space"
    "[SYNTHETIC] hello world"
    (Keeper_synthetic_marker.tag "hello world")

let test_tag_round_trips_through_contains () =
  let text = "anything at all" in
  let tagged = Keeper_synthetic_marker.tag text in
  b "tagged text is detected by contains_marker" true
    (Keeper_synthetic_marker.contains_marker tagged)

let test_contains_marker_negative () =
  b "untagged text -> false" false
    (Keeper_synthetic_marker.contains_marker "no marker here");
  b "lowercase variant -> false (case-sensitive on purpose)" false
    (Keeper_synthetic_marker.contains_marker "[synthetic]");
  b "empty string -> false" false
    (Keeper_synthetic_marker.contains_marker "")

let test_contains_marker_substring () =
  (* The detection path is substring, not prefix — a [SYNTHETIC] marker
     embedded mid-string still flags the entry.  This matches the
     pre-refactor behavior of [String_util.contains_substring s
     "[SYNTHETIC]"]. *)
  b "marker as substring is detected" true
    (Keeper_synthetic_marker.contains_marker
       "decision: [SYNTHETIC] last output: ...")

let () =
  Alcotest.run "keeper_synthetic_marker"
    [
      ( "marker_prefix",
        [ Alcotest.test_case "literal value" `Quick test_marker_prefix_value ] );
      ( "tag",
        [
          Alcotest.test_case "prepends with space" `Quick
            test_tag_prepends_with_space;
          Alcotest.test_case "round-trips through contains_marker" `Quick
            test_tag_round_trips_through_contains;
        ] );
      ( "contains_marker",
        [
          Alcotest.test_case "negative cases" `Quick
            test_contains_marker_negative;
          Alcotest.test_case "marker as substring" `Quick
            test_contains_marker_substring;
        ] );
    ]
