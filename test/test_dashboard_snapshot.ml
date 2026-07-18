(** Unit tests for the Phase 3 prototype landing of RFC-0138.

    Until handler wiring lands, we validate the storage primitive:
    - current () is None before any publish
    - publish_for_test writes a slot, current () reads it
    - reset_for_test clears the slot back to None
    - generation counter is monotonically increasing across snapshots
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

let test_generation_monotonic () =
  Dashboard_snapshot.reset_for_test ();
  let s1 =
    Dashboard_snapshot.make_for_test ~shell:`Null ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null ()
  in
  let s2 =
    Dashboard_snapshot.make_for_test ~shell:`Null ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null ()
  in
  let s3 =
    Dashboard_snapshot.make_for_test ~shell:`Null ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null ()
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
      ~namespace_truth:`Null ~telemetry_summary:`Null ()
  in
  let after = Unix.gettimeofday () in
  Alcotest.(check bool) "generated_at >= before"
    true (s.generated_at >= before);
  Alcotest.(check bool) "generated_at <= after"
    true (s.generated_at <= after)
;;

(* Single-flight: N concurrent callers share exactly one [compute]
   invocation and observe the same snapshot; a populated slot never
   reaches [compute] at all. *)
let test_single_flight_dedups_concurrent_bootstrap () =
  Dashboard_snapshot.reset_for_test ();
  let starter_calls = Atomic.make 0 in
  let snap =
    Dashboard_snapshot.make_for_test
      ~shell:(`String "shared") ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null ()
  in
  let results = Array.make 8 None in
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let start_compute ~resolve =
        ignore (Atomic.fetch_and_add starter_calls 1);
        Eio.Fiber.fork ~sw (fun () ->
          Eio.Time.sleep env#clock 0.05;
          resolve (Ok snap))
      in
      Array.iteri
        (fun i _ ->
          Eio.Fiber.fork ~sw (fun () ->
            results.(i) <-
              Some
                (Dashboard_snapshot.bootstrap_single_flight ~start_compute)
                  .Dashboard_snapshot.generation))
        results));
  Alcotest.(check int) "compute ran exactly once" 1 (Atomic.get starter_calls);
  let generations =
    Array.to_list results
    |> List.filter_map Fun.id
    |> List.sort_uniq compare
  in
  Alcotest.(check int) "all callers saw the same snapshot" 1 (List.length generations)
;;

let test_single_flight_skips_compute_when_populated () =
  Dashboard_snapshot.reset_for_test ();
  let snap =
    Dashboard_snapshot.make_for_test
      ~shell:`Null ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null ()
  in
  Dashboard_snapshot.publish_for_test snap;
  let start_compute ~resolve:_ =
    Alcotest.fail "start_compute ran despite a live snapshot"
  in
  let observed = Dashboard_snapshot.bootstrap_single_flight ~start_compute in
  Alcotest.(check int)
    "returned the published snapshot" snap.generation observed.generation
;;

(* A cancelled caller must not restart the flight: the worker owns the
   marker and the promise, so a mid-flight client disconnect neither
   clears the marker nor blocks the resolution for later callers. *)
let test_caller_cancellation_keeps_flight_alive () =
  Dashboard_snapshot.reset_for_test ();
  let starter_calls = Atomic.make 0 in
  let snap =
    Dashboard_snapshot.make_for_test
      ~shell:(`String "survivor") ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null ()
  in
  let observed = ref None in
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let start_compute ~resolve =
        ignore (Atomic.fetch_and_add starter_calls 1);
        Eio.Fiber.fork ~sw (fun () ->
          Eio.Time.sleep env#clock 0.1;
          resolve (Ok snap))
      in
      (* Caller A disconnects 20ms into the flight. *)
      Eio.Fiber.fork ~sw (fun () ->
        (try
           Eio.Switch.run (fun sw_a ->
             Eio.Fiber.fork ~sw:sw_a (fun () ->
               Eio.Time.sleep env#clock 0.02;
               Eio.Switch.fail sw_a (Failure "client disconnect"));
             ignore
               (Dashboard_snapshot.bootstrap_single_flight ~start_compute))
         with
         | Eio.Cancel.Cancelled _ | Failure _ -> ()));
      (* Caller B joins after A is gone. *)
      Eio.Time.sleep env#clock 0.05;
      observed := Some (Dashboard_snapshot.bootstrap_single_flight ~start_compute)));
  Alcotest.(check int) "starter ran exactly once" 1 (Atomic.get starter_calls);
  match !observed with
  | None -> Alcotest.fail "caller B never observed the flight result"
  | Some t ->
    Alcotest.(check int) "caller B got the worker's snapshot" snap.generation t.generation
;;

(* A worker failure resolves waiters with the error and clears the
   marker so the next caller retries a fresh flight. *)
let test_failure_resolves_error_and_allows_retry () =
  Dashboard_snapshot.reset_for_test ();
  let starter_calls = Atomic.make 0 in
  let snap =
    Dashboard_snapshot.make_for_test
      ~shell:(`String "recovered") ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null ()
  in
  let boom = Failure "provider exploded" in
  let start_compute ~resolve =
    let attempt = Atomic.fetch_and_add starter_calls 1 in
    if attempt = 0
    then resolve (Error (boom, Printexc.get_raw_backtrace ()))
    else resolve (Ok snap)
  in
  (match Dashboard_snapshot.bootstrap_single_flight ~start_compute with
   | exception Failure msg when String.equal msg "provider exploded" -> ()
   | _ -> Alcotest.fail "worker failure was not re-raised to the waiter");
  let recovered = Dashboard_snapshot.bootstrap_single_flight ~start_compute in
  Alcotest.(check int) "retry ran a second flight" 2 (Atomic.get starter_calls);
  Alcotest.(check int) "retry returned the recovered snapshot" snap.generation recovered.generation
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
      ( "single-flight bootstrap",
        [
          Alcotest.test_case "concurrent callers share one compute"
            `Quick test_single_flight_dedups_concurrent_bootstrap;
          Alcotest.test_case "populated slot skips compute"
            `Quick test_single_flight_skips_compute_when_populated;
          Alcotest.test_case "caller cancellation keeps flight alive"
            `Quick test_caller_cancellation_keeps_flight_alive;
          Alcotest.test_case "failure resolves error and allows retry"
            `Quick test_failure_resolves_error_and_allows_retry;
        ] );
    ]
;;
