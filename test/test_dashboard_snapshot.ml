(** Unit tests for the Phase 3 prototype landing of RFC-0138.

    Until handler wiring lands, we validate the storage primitive:
    - current () is None before any publish
    - publish_for_test writes a slot, current () reads it
    - reset_for_test clears the slot back to None
    - generation counter is monotonically increasing across snapshots
    - make_for_test produces a snapshot whose fields are byte-identical
      to its arguments (no transformation, no rounding) *)

open Masc_mcp

let test_current_starts_empty () =
  Dashboard_snapshot.reset_for_test ();
  Alcotest.(check bool) "no live snapshot before publish"
    true (Option.is_none (Dashboard_snapshot.current ()))
;;

let test_publish_then_current () =
  Dashboard_snapshot.reset_for_test ();
  let snap =
    Dashboard_snapshot.make_for_test
      ~shell:(`String "shell-value")
      ~tools:(`String "tools-value")
      ~namespace_truth:(`String "nt-value")
      ~telemetry_summary:(`String "ts-value")
  in
  Dashboard_snapshot.publish_for_test snap;
  match Dashboard_snapshot.current () with
  | None -> Alcotest.fail "expected Some after publish"
  | Some t ->
    Alcotest.(check string) "shell roundtrip"
      "shell-value" (Yojson.Safe.Util.to_string t.shell);
    Alcotest.(check string) "tools roundtrip"
      "tools-value" (Yojson.Safe.Util.to_string t.tools);
    Alcotest.(check string) "namespace_truth roundtrip"
      "nt-value" (Yojson.Safe.Util.to_string t.namespace_truth);
    Alcotest.(check string) "telemetry_summary roundtrip"
      "ts-value" (Yojson.Safe.Util.to_string t.telemetry_summary)
;;

let test_reset_clears_slot () =
  let snap =
    Dashboard_snapshot.make_for_test
      ~shell:`Null ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null
  in
  Dashboard_snapshot.publish_for_test snap;
  Alcotest.(check bool) "populated before reset"
    true (Option.is_some (Dashboard_snapshot.current ()));
  Dashboard_snapshot.reset_for_test ();
  Alcotest.(check bool) "empty after reset"
    true (Option.is_none (Dashboard_snapshot.current ()))
;;

let test_generation_monotonic () =
  Dashboard_snapshot.reset_for_test ();
  let s1 =
    Dashboard_snapshot.make_for_test ~shell:`Null ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null
  in
  let s2 =
    Dashboard_snapshot.make_for_test ~shell:`Null ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null
  in
  let s3 =
    Dashboard_snapshot.make_for_test ~shell:`Null ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null
  in
  Alcotest.(check bool) "s2.generation > s1.generation"
    true (s2.generation > s1.generation);
  Alcotest.(check bool) "s3.generation > s2.generation"
    true (s3.generation > s2.generation)
;;

let test_generated_at_recent () =
  let before = Unix.gettimeofday () in
  let s =
    Dashboard_snapshot.make_for_test ~shell:`Null ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null
  in
  let after = Unix.gettimeofday () in
  Alcotest.(check bool) "generated_at >= before"
    true (s.generated_at >= before);
  Alcotest.(check bool) "generated_at <= after"
    true (s.generated_at <= after)
;;

let () =
  Alcotest.run "Dashboard_snapshot"
    [
      ( "storage",
        [
          Alcotest.test_case "current () empty initially"
            `Quick test_current_starts_empty;
          Alcotest.test_case "publish then current ()"
            `Quick test_publish_then_current;
          Alcotest.test_case "reset clears slot"
            `Quick test_reset_clears_slot;
        ] );
      ( "metadata",
        [
          Alcotest.test_case "generation monotonic"
            `Quick test_generation_monotonic;
          Alcotest.test_case "generated_at within call window"
            `Quick test_generated_at_recent;
        ] );
    ]
;;
