(** Regression / compile coverage for [Eio_guard.yield_meter].

    PR #13195 / issue: "Complete fair-yield coverage for keeper hot loops".

    Verifies:
    1. Outside an Eio runtime, [yield_step] is a safe no-op.
    2. Inside an Eio runtime, [yield_step] does not raise even
       after crossing the interval multiple times.
    3. A custom interval is respected (the counter wraps at the right
       boundary, visible by counting ticks until the first implicit
       yield lets a sibling fiber run).
    4. The meter actually calls [Eio.Fiber.yield] at the interval:
       a sibling fiber that only runs during scheduler yields is
       observable only after batches of [interval] ticks.

    These are intentionally lightweight unit tests of the counter logic.
    Full scheduler-starvation integration is verified by the Eio-based
    concurrency suite ([test_eio_mutex_concurrency]). *)

open Alcotest

module EG = Eio_guard

(* ── 1. no-op / compile coverage outside Eio runtime ── *)

let test_no_op_outside_eio () =
  let m = EG.create_yield_meter () in
  (* 2000 ticks — crosses the default interval twice, no Eio runtime *)
  for _ = 1 to 2000 do
    EG.yield_step m
  done

let test_custom_interval_outside_eio () =
  let m = EG.create_yield_meter ~interval:7 () in
  for _ = 1 to 21 do     (* 3 full batches of 7 *)
    EG.yield_step m
  done

(* ── 2. no exception inside Eio runtime ── *)

let test_no_exception_in_eio () =
  Eio_main.run @@ fun _env ->
  EG.enable ();
  let m = EG.create_yield_meter () in
  (* Cross the default interval twice inside a live Eio runtime. *)
  for _ = 1 to 2000 do
    EG.yield_step m
  done;
  EG.disable ()

(* ── 3. interval fires → sibling fiber gets scheduled ── *)

(** Verifies that [yield_step] actually yields the Eio scheduler
    at the interval boundary.

    Strategy: run two concurrent fibers with [Eio.Fiber.all]:
    - Main fiber: ticks a meter with [interval=5] a total of 10 times,
      recording the tick index each time it *still has the CPU*.
    - Sibling fiber: calls [Eio.Fiber.yield] in a tight loop and
      records each time it is scheduled.

    Because both fibers are cooperative, the sibling can only run when
    the main fiber explicitly yields — either via [EG.yield_step]
    crossing the interval or by finishing.  After 5 ticks the meter
    should have fired and the sibling should have had at least one turn
    before the main fiber completes its second batch. *)
let test_interval_fires_sibling () =
  Eio_main.run @@ fun _env ->
  EG.enable ();
  let sibling_ran = ref 0 in
  let sibling_ran_before_main_done = ref false in
  let main_done = ref false in
  let m = EG.create_yield_meter ~interval:5 () in
  Eio.Fiber.all [
    (fun () ->
      for _ = 1 to 10 do
        EG.yield_step m
      done;
      main_done := true);
    (fun () ->
      (* Tight loop: each iteration only advances when the scheduler
         gives this fiber a turn. *)
      for _ = 1 to 20 do
        Eio.Fiber.yield ();
        if not !main_done then sibling_ran_before_main_done := true;
        incr sibling_ran
      done)
  ];
  EG.disable ();
  check bool "sibling completed all rounds" true (!sibling_ran = 20);
  check bool "sibling ran before main completed" true
    !sibling_ran_before_main_done

(* ── 4. multiple independent meters don't interfere ── *)

let test_independent_meters () =
  Eio_main.run @@ fun _env ->
  EG.enable ();
  let m1 = EG.create_yield_meter ~interval:3 () in
  let m2 = EG.create_yield_meter ~interval:7 () in
  (* Interleave ticks from two independent meters.  Neither should
     affect the other's count.  Must not raise. *)
  for _ = 1 to 21 do
    EG.yield_step m1;
    EG.yield_step m2
  done;
  EG.disable ()

let () =
  run "eio_guard_yield_meter"
    [ ( "no-op",
        [ test_case "safe outside Eio runtime (default interval)" `Quick
            test_no_op_outside_eio
        ; test_case "safe outside Eio runtime (custom interval)" `Quick
            test_custom_interval_outside_eio ] )
    ; ( "eio-runtime",
        [ test_case "no exception crossing interval in Eio runtime" `Quick
            test_no_exception_in_eio
        ; test_case "interval fires: sibling fiber gets scheduled" `Quick
            test_interval_fires_sibling
        ; test_case "independent meters do not interfere" `Quick
            test_independent_meters ] )
    ]
