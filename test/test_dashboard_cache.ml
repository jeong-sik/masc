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

(* -- 2. Triple nesting (mirrors room-truth -> execution -> snapshot) -------- *)

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

(* -- 5. Stats reports active + computing ------------------------------------ *)

let test_stats () =
  Dashboard_cache.invalidate_all ();
  ignore (Dashboard_cache.get_or_compute "s1" ~ttl:10.0 (fun () -> `Null));
  ignore (Dashboard_cache.get_or_compute "s2" ~ttl:10.0 (fun () -> `Null));
  let stats = Dashboard_cache.stats () in
  let active = Yojson.Safe.Util.(member "active" stats |> to_int) in
  Alcotest.(check int) "2 active entries" 2 active

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

(* -- Harness ---------------------------------------------------------------- *)

let () =
  Eio_main.run @@ fun _env ->
  Dashboard_cache.enable_eio ();
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
          test_case "invalidate" `Quick test_invalidate;
          test_case "stats" `Quick test_stats;
          test_case "exception recovery" `Quick test_exception_recovery;
          test_case "invalidate_all wakes waiters" `Quick
            test_invalidate_all_wakes_waiters;
        ] );
      ( "concurrency",
        [
          test_case "stampede protection" `Quick test_stampede;
        ] );
    ]
