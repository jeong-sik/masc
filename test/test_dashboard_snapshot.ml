(** Unit tests for the Phase 3 prototype landing of RFC-0138.

    Until handler wiring lands, we validate the storage primitive:
    - current () is None before any publish
    - publish_for_test writes a slot, current () reads it
    - reset_for_test clears the slot back to None
    - make_for_test produces a snapshot whose fields are byte-identical
      to its arguments (no transformation, no rounding) *)

open Masc

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
      ()
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
      ~namespace_truth:`Null ~telemetry_summary:`Null ()
  in
  Dashboard_snapshot.publish_for_test snap;
  Alcotest.(check bool) "populated before reset"
    true (Option.is_some (Dashboard_snapshot.current ()));
  Dashboard_snapshot.reset_for_test ();
  Alcotest.(check bool) "empty after reset"
    true (Option.is_none (Dashboard_snapshot.current ()))
;;

let test_generated_at_recent () =
  let before = Unix.gettimeofday () in
  let s =
    Dashboard_snapshot.make_for_test ~shell:`Null ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null ()
  in
  let after = Unix.gettimeofday () in
  Alcotest.(check bool) "generated_at >= before"
    true (s.generated_at >= before);
  Alcotest.(check bool) "generated_at <= after"
    true (s.generated_at <= after)
;;

let test_projection_ttl_reuse_boundaries () =
  let reuse ~now ~ttl ~refreshed_at =
    Dashboard_snapshot.For_testing.should_reuse_projection
      ~now ~ttl ~refreshed_at
  in
  Alcotest.(check bool) "inside ttl reuses" true
    (reuse ~now:109.9 ~ttl:10.0 ~refreshed_at:100.0);
  Alcotest.(check bool) "ttl boundary refreshes" false
    (reuse ~now:110.0 ~ttl:10.0 ~refreshed_at:100.0);
  Alcotest.(check bool) "clock rollback refreshes" false
    (reuse ~now:99.0 ~ttl:10.0 ~refreshed_at:100.0)
;;

let test_projection_cache_retains_last_good_and_successful_null () =
  let now_value = ref 100.0 in
  let now () = !now_value in
  let calls = ref 0 in
  let cache = Dashboard_snapshot.For_testing.make_cache () in
  let refresh compute =
    Dashboard_snapshot.For_testing.refresh_projection
      ~now ~ttl:10.0 ~cache compute
  in
  let first = refresh (fun () -> incr calls; `String "good") in
  Alcotest.(check string) "first success" "good" (Yojson.Safe.Util.to_string first);
  now_value := 105.0;
  let hit = refresh (fun () -> incr calls; `String "unexpected") in
  Alcotest.(check string) "fresh hit" "good" (Yojson.Safe.Util.to_string hit);
  Alcotest.(check int) "fresh hit skips callback" 1 !calls;
  now_value := 111.0;
  let fallback = refresh (fun () -> incr calls; failwith "refresh failed") in
  Alcotest.(check string) "failed refresh keeps last good" "good"
    (Yojson.Safe.Util.to_string fallback);
  let null_cache = Dashboard_snapshot.For_testing.make_cache () in
  now_value := 200.0;
  let null_calls = ref 0 in
  ignore
    (Dashboard_snapshot.For_testing.refresh_projection
       ~now ~ttl:10.0 ~cache:null_cache
       (fun () -> incr null_calls; `Null));
  now_value := 205.0;
  ignore
    (Dashboard_snapshot.For_testing.refresh_projection
       ~now ~ttl:10.0 ~cache:null_cache
       (fun () -> incr null_calls; `String "unexpected"));
  Alcotest.(check int) "successful null is cached" 1 !null_calls;
  let cold_cache = Dashboard_snapshot.For_testing.make_cache () in
  Alcotest.check_raises "cold failure aborts publish" (Failure "cold")
    (fun () ->
       ignore
         (Dashboard_snapshot.For_testing.refresh_projection
            ~now ~ttl:10.0 ~cache:cold_cache
            (fun () -> failwith "cold")))
;;

let test_activity_defaults_cache_retains_last_good () =
  let now_value = ref 100.0 in
  let now () = !now_value in
  let calls = ref 0 in
  let cache = Dashboard_snapshot.For_testing.make_activity_cache () in
  let refresh compute =
    Dashboard_snapshot.For_testing.refresh_activity_defaults
      ~now ~ttl:10.0 ~cache compute
  in
  let dummy1 : Activity_graph.default_projections =
    { events_default = `String "e1"
    ; graph_default = `String "g1"
    ; swimlane_default = `String "s1"
    }
  in
  let dummy2 : Activity_graph.default_projections =
    { events_default = `String "e2"
    ; graph_default = `String "g2"
    ; swimlane_default = `String "s2"
    }
  in
  let first = refresh (fun () -> incr calls; dummy1) in
  Alcotest.(check string) "first success" "e1"
    (Yojson.Safe.Util.to_string first.events_default);
  now_value := 105.0;
  let hit = refresh (fun () -> incr calls; dummy2) in
  Alcotest.(check string) "fresh hit" "e1"
    (Yojson.Safe.Util.to_string hit.events_default);
  Alcotest.(check int) "fresh hit skips callback" 1 !calls;
  now_value := 111.0;
  let fallback = refresh (fun () -> incr calls; failwith "refresh failed") in
  Alcotest.(check string) "failed refresh keeps last good" "e1"
    (Yojson.Safe.Util.to_string fallback.events_default);
  let cold_cache = Dashboard_snapshot.For_testing.make_activity_cache () in
  Alcotest.check_raises "cold failure aborts publish" (Failure "cold")
    (fun () ->
       ignore
         (Dashboard_snapshot.For_testing.refresh_activity_defaults
            ~now ~ttl:10.0 ~cache:cold_cache
            (fun () -> failwith "cold")))
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
          Alcotest.test_case "generated_at within call window"
            `Quick test_generated_at_recent;
          Alcotest.test_case "projection ttl reuse boundaries"
            `Quick test_projection_ttl_reuse_boundaries;
          Alcotest.test_case "projection cache keeps last good and null"
            `Quick test_projection_cache_retains_last_good_and_successful_null;
          Alcotest.test_case "activity defaults cache keeps last good"
            `Quick test_activity_defaults_cache_retains_last_good;
        ] );
    ]
;;
