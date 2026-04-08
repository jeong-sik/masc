(** Admission Queue Coverage Tests

    Tests for MASC inference admission queue:
    - Basic acquire/release
    - Concurrency limit enforcement
    - Priority ordering
    - Cancel safety
    - Exception safety
    - Snapshot accuracy
    - try_with_permit behavior
    - set_max_concurrent validation
*)

open Alcotest

module AQ = Masc_mcp.Admission_queue

(* ============================================================
   Basic Tests
   ============================================================ *)

let test_with_permit_runs () =
  Eio_main.run (fun _env ->
    AQ.reset_for_test ~max_slots:4;
    let result = AQ.with_permit ~priority:Interactive
      ~keeper_name:"test" ~cascade_name:"test" (fun () -> 42) in
    check int "runs and returns" 42 result)

let test_with_permit_releases_on_exception () =
  Eio_main.run (fun _env ->
    AQ.reset_for_test ~max_slots:4;
    (try AQ.with_permit ~priority:Interactive
       ~keeper_name:"test" ~cascade_name:"test"
       (fun () -> failwith "boom")
     with Failure _ -> ());
    let s = AQ.snapshot () in
    check int "active after exception" 0 s.active)

let test_snapshot_empty () =
  Eio_main.run (fun _env ->
    AQ.reset_for_test ~max_slots:4;
    let s = AQ.snapshot () in
    check int "max_concurrent" 4 s.max_concurrent;
    check int "active" 0 s.active;
    check int "available" 4 s.available;
    check int "queue_depth" 0 s.queue_depth)

let test_snapshot_during_permit () =
  Eio_main.run (fun _env ->
    AQ.reset_for_test ~max_slots:2;
    AQ.with_permit ~priority:Interactive
      ~keeper_name:"test" ~cascade_name:"test"
      (fun () ->
        let s = AQ.snapshot () in
        check int "active" 1 s.active;
        check int "available" 1 s.available))

(* ============================================================
   try_with_permit Tests
   ============================================================ *)

let test_try_succeeds_when_available () =
  Eio_main.run (fun _env ->
    AQ.reset_for_test ~max_slots:2;
    let result = AQ.try_with_permit ~priority:Interactive
      ~keeper_name:"test" ~cascade_name:"test" (fun () -> 42) in
    check (option int) "succeeds" (Some 42) result)

let test_try_returns_none_when_full () =
  Eio_main.run (fun _env ->
    AQ.reset_for_test ~max_slots:1;
    AQ.with_permit ~priority:Interactive
      ~keeper_name:"holder" ~cascade_name:"test"
      (fun () ->
        let result = AQ.try_with_permit ~priority:Background
          ~keeper_name:"waiter" ~cascade_name:"test"
          (fun () -> 99) in
        check (option int) "returns None" None result))

(* ============================================================
   Concurrency Limit Tests
   ============================================================ *)

let test_concurrency_limit () =
  Eio_main.run (fun _env ->
    AQ.reset_for_test ~max_slots:2;
    let max_seen = Atomic.make 0 in
    let current = Atomic.make 0 in
    let run_one name =
      AQ.with_permit ~priority:Proactive
        ~keeper_name:name ~cascade_name:"test"
        (fun () ->
          let c = Atomic.fetch_and_add current 1 + 1 in
          let prev = Atomic.get max_seen in
          if c > prev then Atomic.set max_seen c;
          Eio.Fiber.yield ();
          ignore (Atomic.fetch_and_add current (-1)))
    in
    Eio.Fiber.all [
      (fun () -> run_one "k1");
      (fun () -> run_one "k2");
      (fun () -> run_one "k3");
      (fun () -> run_one "k4");
    ];
    let max_concurrent = Atomic.get max_seen in
    check bool "max concurrent <= 2" true (max_concurrent <= 2))

(* ============================================================
   Priority Ordering Tests
   ============================================================ *)

let test_priority_ordering () =
  Eio_main.run (fun _env ->
    AQ.reset_for_test ~max_slots:1;
    let order = ref [] in
    let hold, release_hold = Eio.Promise.create () in
    Eio.Fiber.both
      (fun () ->
        AQ.with_permit ~priority:Background
          ~keeper_name:"blocker" ~cascade_name:"test"
          (fun () -> Eio.Promise.await hold))
      (fun () ->
        Eio.Fiber.both
          (fun () ->
            Eio.Fiber.both
              (fun () ->
                Eio.Fiber.yield ();
                AQ.with_permit ~priority:Background
                  ~keeper_name:"bg" ~cascade_name:"test"
                  (fun () -> order := "bg" :: !order))
              (fun () ->
                Eio.Fiber.yield ();
                AQ.with_permit ~priority:Interactive
                  ~keeper_name:"int" ~cascade_name:"test"
                  (fun () -> order := "int" :: !order)))
          (fun () ->
            Eio.Fiber.yield ();
            Eio.Fiber.yield ();
            Eio.Fiber.yield ();
            Eio.Promise.resolve release_hold ()));
    check (list string) "interactive first"
      ["bg"; "int"] !order)

(* ============================================================
   Cancel Safety Tests
   ============================================================ *)

let test_cancel_no_leak () =
  Eio_main.run (fun _env ->
    AQ.reset_for_test ~max_slots:1;
    let hold, release_hold = Eio.Promise.create () in
    Eio.Fiber.both
      (fun () ->
        AQ.with_permit ~priority:Interactive
          ~keeper_name:"blocker" ~cascade_name:"test"
          (fun () -> Eio.Promise.await hold))
      (fun () ->
        Eio.Fiber.both
          (fun () ->
            Eio.Fiber.yield ();
            (try AQ.with_permit ~priority:Background
               ~keeper_name:"cancelled" ~cascade_name:"test"
               (fun () -> ())
             with Eio.Cancel.Cancelled _ -> ()))
          (fun () ->
            Eio.Fiber.yield ();
            Eio.Fiber.yield ();
            Eio.Promise.resolve release_hold ()));
    let s = AQ.snapshot () in
    check int "no leaked slots" 0 s.active)

(* ============================================================
   Configuration Tests
   ============================================================ *)

let test_set_max_concurrent () =
  Eio_main.run (fun _env ->
    AQ.reset_for_test ~max_slots:4;
    AQ.set_max_concurrent 8;
    check int "updated" 8 (AQ.max_concurrent ());
    AQ.set_max_concurrent 4)

let test_set_max_concurrent_rejects_zero () =
  try AQ.set_max_concurrent 0; fail "should raise"
  with Invalid_argument _ -> ()

let test_snapshot_json_shape () =
  Eio_main.run (fun _env ->
    AQ.reset_for_test ~max_slots:4;
    let json = AQ.snapshot_json () in
    match json with
    | `Assoc fields ->
      check bool "has max_concurrent" true
        (List.mem_assoc "max_concurrent" fields);
      check bool "has queue_depth" true
        (List.mem_assoc "queue_depth" fields);
      check bool "has waiters" true
        (List.mem_assoc "waiters" fields)
    | _ -> fail "expected Assoc")

(* ============================================================
   Runner
   ============================================================ *)

let () =
  run "Admission_queue" [
    "basic", [
      test_case "with_permit runs" `Quick test_with_permit_runs;
      test_case "releases on exception" `Quick test_with_permit_releases_on_exception;
      test_case "snapshot empty" `Quick test_snapshot_empty;
      test_case "snapshot during permit" `Quick test_snapshot_during_permit;
    ];
    "try_with_permit", [
      test_case "succeeds when available" `Quick test_try_succeeds_when_available;
      test_case "returns None when full" `Quick test_try_returns_none_when_full;
    ];
    "concurrency", [
      test_case "enforces limit" `Quick test_concurrency_limit;
    ];
    "priority", [
      test_case "ordering" `Quick test_priority_ordering;
    ];
    "cancel", [
      test_case "no slot leak" `Quick test_cancel_no_leak;
    ];
    "config", [
      test_case "set_max_concurrent" `Quick test_set_max_concurrent;
      test_case "rejects zero" `Quick test_set_max_concurrent_rejects_zero;
      test_case "snapshot_json shape" `Quick test_snapshot_json_shape;
    ];
  ]
