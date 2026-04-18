(** Dashboard_cache deadlock regression + stampede + expiry tests.

    These tests run inside [Eio_main.run] so that [Eio.Mutex] and
    [Eio.Condition] are fully operational. *)

open Masc_mcp

let check_json msg expected actual =
  Alcotest.(check string) msg
    (Yojson.Safe.to_string expected)
    (Yojson.Safe.to_string actual)

(* -- 1. Nested get_or_compute must not deadlock ----------------------------- *)

let test_nested_no_deadlock () =
  Dashboard_cache.invalidate_all ();
  let result =
    Dashboard_cache.get_or_compute "outer" ~ttl:5.0 (fun () ->
      let inner =
        Dashboard_cache.get_or_compute "inner" ~ttl:5.0 (fun () ->
          `String "inner_ok")
      in
      `Assoc [("inner", inner)])
  in
  check_json "nested no deadlock"
    (`Assoc [("inner", `String "inner_ok")])
    result

(* -- 2. Triple nesting (mirrors namespace-truth -> execution -> snapshot) --- *)

let test_triple_nesting () =
  Dashboard_cache.invalidate_all ();
  let result =
    Dashboard_cache.get_or_compute "level1" ~ttl:5.0 (fun () ->
      let l2 =
        Dashboard_cache.get_or_compute "level2" ~ttl:5.0 (fun () ->
          let l3 =
            Dashboard_cache.get_or_compute "level3" ~ttl:5.0 (fun () ->
              `String "deep")
          in
          `Assoc [("l3", l3)])
      in
      `Assoc [("l2", l2)])
  in
  check_json "triple nesting"
    (`Assoc [("l2", `Assoc [("l3", `String "deep")])])
    result

(* -- 3. Cache hit: second call skips compute -------------------------------- *)

let test_cache_hit () =
  Dashboard_cache.invalidate_all ();
  let counter = ref 0 in
  let compute () = incr counter; `Int !counter in
  let v1 = Dashboard_cache.get_or_compute "hit" ~ttl:5.0 compute in
  let v2 = Dashboard_cache.get_or_compute "hit" ~ttl:5.0 compute in
  check_json "same value" v1 v2;
  Alcotest.(check int) "compute once" 1 !counter

let test_peek_returns_cached_value () =
  Dashboard_cache.invalidate_all ();
  let seeded =
    Dashboard_cache.get_or_compute "peek-hit" ~ttl:5.0 (fun () ->
        `String "cached")
  in
  let peeked = Dashboard_cache.peek "peek-hit" in
  Alcotest.(check bool) "peek returns some" true (Option.is_some peeked);
  check_json "peeked value" seeded
    (Option.value ~default:`Null peeked)

(* -- 4. Invalidate removes entry -------------------------------------------- *)

let test_invalidate () =
  Dashboard_cache.invalidate_all ();
  let counter = ref 0 in
  let compute () = incr counter; `Int !counter in
  ignore (Dashboard_cache.get_or_compute "inv" ~ttl:5.0 compute);
  Dashboard_cache.invalidate "inv";
  let v = Dashboard_cache.get_or_compute "inv" ~ttl:5.0 compute in
  Alcotest.(check int) "recompute after invalidate" 2 !counter;
  check_json "new value" (`Int 2) v

let test_invalidate_prefix () =
  Dashboard_cache.invalidate_all ();
  let proof_counter = ref 0 in
  let mission_counter = ref 0 in
  ignore
    (Dashboard_cache.get_or_compute "proof:room-a:default:one" ~ttl:5.0
       (fun () ->
         incr proof_counter;
         `Int !proof_counter));
  ignore
    (Dashboard_cache.get_or_compute "proof:room-a:default:two" ~ttl:5.0
       (fun () ->
         incr proof_counter;
         `Int !proof_counter));
  ignore
    (Dashboard_cache.get_or_compute "mission:room-a:default:one" ~ttl:5.0
       (fun () ->
         incr mission_counter;
         `Int !mission_counter));
  Dashboard_cache.invalidate_prefix "proof:room-a:default:";
  ignore
    (Dashboard_cache.get_or_compute "proof:room-a:default:one" ~ttl:5.0
       (fun () ->
         incr proof_counter;
         `Int !proof_counter));
  ignore
    (Dashboard_cache.get_or_compute "proof:room-a:default:two" ~ttl:5.0
       (fun () ->
         incr proof_counter;
         `Int !proof_counter));
  ignore
    (Dashboard_cache.get_or_compute "mission:room-a:default:one" ~ttl:5.0
       (fun () ->
         incr mission_counter;
         `Int !mission_counter));
  Alcotest.(check int) "proof entries recomputed" 4 !proof_counter;
  Alcotest.(check int) "non-matching prefix preserved" 1 !mission_counter

(* -- 5. Stats reports active + computing ------------------------------------ *)

let test_stats () =
  Dashboard_cache.invalidate_all ();
  ignore (Dashboard_cache.get_or_compute "s1" ~ttl:10.0 (fun () -> `Null));
  ignore (Dashboard_cache.get_or_compute "s2" ~ttl:10.0 (fun () -> `Null));
  let stats = Dashboard_cache.stats () in
  let fresh = Yojson.Safe.Util.(member "ready_fresh" stats |> to_int) in
  Alcotest.(check int) "2 fresh entries" 2 fresh

(* -- 6. Stampede: N fibers, same key -> compute runs once ------------------- *)

let test_stampede () =
  Dashboard_cache.invalidate_all ();
  let compute_count = Atomic.make 0 in
  let slow_compute () =
    Atomic.incr compute_count;
    (* Yield to let other fibers attempt get_or_compute *)
    Eio.Fiber.yield ();
    `String "computed"
  in
  Eio.Fiber.all [
    (fun () -> ignore (Dashboard_cache.get_or_compute "stmp" ~ttl:5.0 slow_compute));
    (fun () -> ignore (Dashboard_cache.get_or_compute "stmp" ~ttl:5.0 slow_compute));
    (fun () -> ignore (Dashboard_cache.get_or_compute "stmp" ~ttl:5.0 slow_compute));
  ];
  Alcotest.(check int) "stampede: compute once" 1 (Atomic.get compute_count)

(* -- 7. Exception during compute: key cleaned up, next call retries --------- *)

let test_exception_recovery () =
  Dashboard_cache.invalidate_all ();
  let raised =
    (try
       ignore
         (Dashboard_cache.get_or_compute "fail" ~ttl:5.0 (fun () ->
            failwith "boom"));
       false
     with Failure _ -> true)
  in
  Alcotest.(check bool) "exception propagated" true raised;
  (* Key should be removed -- next call recomputes *)
  let v =
    Dashboard_cache.get_or_compute "fail" ~ttl:5.0 (fun () ->
      `String "recovered")
  in
  check_json "recovered after exception" (`String "recovered") v

(* -- 8. Invalidate_all wakes Computing waiters ------------------------------ *)

let test_invalidate_all_wakes_waiters () =
  Dashboard_cache.invalidate_all ();
  let finished = Atomic.make false in
  Eio.Fiber.both
    (fun () ->
       (* This fiber will block waiting for "blocking" to be computed *)
       let v =
         Dashboard_cache.get_or_compute "blocking" ~ttl:5.0 (fun () ->
           (* Signal that compute started, then yield to let waiter attach *)
           Eio.Fiber.yield ();
           `String "first")
       in
       check_json "first compute" (`String "first") v)
    (fun () ->
       (* Let the first fiber start computing *)
       Eio.Fiber.yield ();
       Eio.Fiber.yield ();
       (* invalidate_all should clear everything *)
       Dashboard_cache.invalidate_all ();
       Atomic.set finished true);
  Alcotest.(check bool) "both fibers finished" true (Atomic.get finished)

(* -- 9. Timeout during stale-while-revalidate preserves stale value -------- *)

(** When [get_or_compute_with_timeout] is called for a stale (but within grace)
    entry and the recomputation times out, the stale value must be preserved in
    the cache.  The caller receives the stale value immediately, and the
    background fiber's Compute_timeout exception triggers the restore path.
    A subsequent cache lookup must return the stale value, not timeout-error
    JSON.  (Regression test for Codex review P2 on PR #1314.) *)
let test_stale_preserved_on_timeout ~clock ~sw () =
  Dashboard_cache.invalidate_all ();
  Eio_context.set_switch sw;
  let original = `String "original_data" in
  (* 1. Seed the cache with a short-lived entry (TTL 0.1s, stale grace 0.3s) *)
  let v0 =
    Dashboard_cache.get_or_compute "stale_timeout" ~ttl:0.1 (fun () -> original)
  in
  check_json "seed" original v0;
  (* 2. Wait for expiry but stay within stale grace *)
  Eio.Time.sleep clock 0.15;
  (* 3. Call with timeout shorter than compute time — compute will time out.
     The function should return the stale value immediately. *)
  let result =
    Dashboard_cache.get_or_compute_with_timeout "stale_timeout" ~ttl:0.1
      ~clock ~timeout_sec:0.05 (fun () ->
        (* Simulate slow computation that exceeds timeout *)
        Eio.Time.sleep clock 1.0;
        `String "never_reached")
  in
  check_json "stale value returned on timeout" original result;
  (* 4. Let the background fiber finish (it will timeout + restore stale) *)
  Eio.Fiber.yield ();
  Eio.Time.sleep clock 0.1;
  (* 5. Subsequent lookup: must get stale data or recompute, NOT timeout JSON *)
  let after =
    Dashboard_cache.get_or_compute "stale_timeout" ~ttl:0.1 (fun () ->
      `String "fresh_recompute")
  in
  let is_timeout_error =
    match after with
    | `Assoc pairs ->
      (match List.assoc_opt "error" pairs with
       | Some (`String "computation_timeout") -> true
       | _ -> false)
    | _ -> false
  in
  Alcotest.(check bool) "no timeout error cached" false is_timeout_error

(* -- 10. Timeout with no stale data returns error JSON (not cached) -------- *)

(** When there is no stale data (first compute for a key), timeout should
    return error JSON to the caller but NOT cache it — subsequent calls
    should trigger a fresh recompute. *)
let test_timeout_no_stale_returns_error ~clock () =
  Dashboard_cache.invalidate_all ();
  let result =
    Dashboard_cache.get_or_compute_with_timeout "no_stale_timeout" ~ttl:1.0
      ~clock ~timeout_sec:0.05 (fun () ->
        Eio.Time.sleep clock 1.0;
        `String "never_reached")
  in
  (* Should get timeout error JSON *)
  let is_timeout_error =
    match result with
    | `Assoc pairs ->
      (match List.assoc_opt "error" pairs with
       | Some (`String "computation_timeout") -> true
       | _ -> false)
    | _ -> false
  in
  Alcotest.(check bool) "timeout error returned" true is_timeout_error;
  (* Next call should recompute, not return cached error *)
  let v2 =
    Dashboard_cache.get_or_compute "no_stale_timeout" ~ttl:1.0 (fun () ->
      `String "recovered")
  in
  check_json "recompute after timeout" (`String "recovered") v2

(* -- 11. Waiter timeout returns fast error without poisoning cache --------- *)

(** When another fiber already owns the compute slot, waiters should honor the
    caller's timeout budget instead of waiting for the global 130s eviction.
    The timeout response must not poison the cache; once the owner finishes,
    subsequent reads should observe the completed value. *)
let test_waiter_timeout_returns_error_not_cached ~clock () =
  Dashboard_cache.invalidate_all ();
  let owner_finished, resolve_owner_finished = Eio.Promise.create () in
  let waiter_result = ref `Null in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
    ignore
      (Dashboard_cache.get_or_compute_with_timeout "waiter_timeout" ~ttl:1.0
         ~clock ~timeout_sec:1.0 (fun () ->
           Eio.Time.sleep clock 0.4;
           `String "owner_done"));
    Eio.Promise.resolve resolve_owner_finished ());
  Eio.Time.sleep clock 0.05;
  waiter_result :=
    Dashboard_cache.get_or_compute_with_timeout "waiter_timeout" ~ttl:1.0
      ~clock ~timeout_sec:0.15 (fun () ->
        `String "waiter_should_not_compute");
  Eio.Promise.await owner_finished;
  let timeout_kind =
    Yojson.Safe.Util.(member "timeout_kind" !waiter_result |> to_string)
  in
  Alcotest.(check string) "waiter timeout is classified" "waiter" timeout_kind;
  let final =
    Dashboard_cache.get_or_compute "waiter_timeout" ~ttl:1.0 (fun () ->
      `String "unexpected_recompute")
  in
  check_json "owner result survives waiter timeout" (`String "owner_done") final

(* -- Harness ---------------------------------------------------------------- *)

let () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio_guard.enable ();
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let open Alcotest in
  run ~and_exit:false "Dashboard_cache"
    [
      ( "deadlock",
        [
          test_case "nested get_or_compute" `Quick test_nested_no_deadlock;
          test_case "triple nesting" `Quick test_triple_nesting;
        ] );
      ( "correctness",
        [
          test_case "cache hit" `Quick test_cache_hit;
          test_case "peek returns cached value" `Quick
            test_peek_returns_cached_value;
          test_case "invalidate" `Quick test_invalidate;
          test_case "invalidate_prefix" `Quick test_invalidate_prefix;
          test_case "stats" `Quick test_stats;
          test_case "exception recovery" `Quick test_exception_recovery;
          test_case "invalidate_all wakes waiters" `Quick
            test_invalidate_all_wakes_waiters;
        ] );
      ( "concurrency",
        [
          test_case "stampede protection" `Quick test_stampede;
        ] );
      ( "timeout",
        [
          test_case "stale preserved on timeout" `Quick
            (fun () ->
               Eio.Switch.run @@ fun sw ->
               test_stale_preserved_on_timeout ~clock ~sw ());
          test_case "no-stale timeout returns error, not cached" `Quick
            (test_timeout_no_stale_returns_error ~clock);
          test_case "waiter timeout returns error, not cached" `Quick
            (test_waiter_timeout_returns_error_not_cached ~clock);
        ] );
    ]
