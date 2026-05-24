(** Unit tests for [Masc_mcp.Cascade_tier_wait_scheduler].

    RFC-0153 Phase C.1. Tests:
    - Immediate admission (no wait) when capacity available
    - Wait + admitted when slot released during backoff
    - Timeout expired when no release within deadline
    - Max retries exceeded
    - Exception propagation preserves release
    - Stats observability *)

open Alcotest

module A = Masc_mcp.Cascade_tier_admission
module W = Masc_mcp.Cascade_tier_wait_scheduler

let float_approx msg expected actual =
  let tolerance = 0.5 in
  check bool msg true (Float.abs (expected -. actual) < tolerance)

let int_check msg expected actual =
  check int msg expected actual

(* {1 Immediate admission — no wait} *)

let test_immediate_admit () =
  Eio_main.run (fun _env ->
  let admission = A.create ~default_max_inflight:2 () in
  let scheduler = W.create ~clock:(Eio.Stdenv.clock _env) admission in
  Eio.Switch.run @@ fun sw ->
  match W.try_admission_or_wait scheduler ~tier_id:"test" ~sw
          (fun () -> 42) with
  | Ok v -> check int "immediate admit returns 42" 42 v
  | Error re ->
      fail ("unexpected rejection: " ^ Format.asprintf "%a" W.pp_rejection_detail re))

let test_immediate_admit_simple () =
  Eio_main.run (fun _env ->
  let admission = A.create ~default_max_inflight:2 () in
  let scheduler = W.create ~clock:(Eio.Stdenv.clock _env) admission in
  Eio.Switch.run @@ fun sw ->
  match W.try_admission_or_wait scheduler ~tier_id:"test" ~sw
          (fun () -> "hello") with
  | Ok v ->
      check string "immediate admit returns hello" "hello" v;
      check int "inflight back to 0 after f returns"
        0 (A.current_inflight admission ~tier_id:"test")
  | Error re ->
      fail ("unexpected rejection: " ^ Format.asprintf "%a" W.pp_rejection_detail re))

(* {1 Capacity full + wait + release → admitted} *)

let test_wait_then_admit () =
  Eio_main.run (fun _env ->
  let admission = A.create ~default_max_inflight:1 () in
  let scheduler = W.create ~clock:(Eio.Stdenv.clock _env) admission in
  Eio.Switch.run @@ fun sw ->
  (* Fill the slot *)
  let blocker_started, blocker_started_r = Eio.Promise.create () in
  let release_blocker, resolve_release = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      ignore (W.try_admission_or_wait scheduler ~tier_id:"test" ~sw
                (fun () ->
                   Eio.Promise.resolve blocker_started_r ();
                   Eio.Promise.await release_blocker;
                   "blocker_done")));
  (* Wait for blocker to take the slot *)
  Eio.Promise.await blocker_started;
  check int "blocker holds the slot" 1
    (A.current_inflight admission ~tier_id:"test");
  (* Configure very short wait for test speed *)
  let fast_config = {
    W.backoff = W.Constant 0.01;
    timeout_s = 5.0;
    max_retries = None;
  } in
  (* Start waiter in a fork — it will block until release *)
  let waiter_done, waiter_done_r = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      let r = W.try_admission_or_wait scheduler ~tier_id:"test"
                ~wait_config:fast_config ~sw
                (fun () -> "waiter_done") in
      Eio.Promise.resolve waiter_done_r r);
  (* Give the waiter time to enter wait loop *)
  Eio.Fiber.yield ();
  Eio.Fiber.yield ();
  (* Release the blocker *)
  Eio.Promise.resolve resolve_release ();
  (* Wait for waiter to complete *)
  match Eio.Promise.await waiter_done with
  | Ok v ->
      check string "waiter got admitted" "waiter_done" v
  | Error re ->
      fail ("waiter rejected: " ^ Format.asprintf "%a" W.pp_rejection_detail re))

(* {1 Timeout expired} *)

let test_timeout_expired () =
  Eio_main.run (fun _env ->
  let admission = A.create ~default_max_inflight:1 () in
  let scheduler = W.create ~clock:(Eio.Stdenv.clock _env) admission in
  Eio.Switch.run @@ fun sw ->
  (* Fill the slot permanently — use daemon fiber so switch.run
     can return when the main fiber finishes *)
  let blocker_started, blocker_started_r = Eio.Promise.create () in
  let blocker_never_release_p, _ = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      ignore (W.try_admission_or_wait scheduler ~tier_id:"test" ~sw
                (fun () ->
                   Eio.Promise.resolve blocker_started_r ();
                   Eio.Promise.await blocker_never_release_p;
                   "never"));
      `Stop_daemon);
  Eio.Promise.await blocker_started;
  (* Try with very short timeout *)
  let fast_timeout = {
    W.backoff = W.Constant 0.001;
    timeout_s = 0.05;
    max_retries = None;
  } in
  match W.try_admission_or_wait scheduler ~tier_id:"test"
          ~wait_config:fast_timeout ~sw
          (fun () -> "should_not_run") with
  | Error (W.Timeout_expired { tier_id; attempts; _ }) ->
      check string "tier_id matches" "test" tier_id;
      check bool "attempts > 0" true (attempts > 0)
  | Error other ->
      fail ("wrong rejection type: " ^ Format.asprintf "%a" W.pp_rejection_detail other)
  | Ok _ ->
      fail "should have timed out")

(* {1 Max retries exceeded} *)

let test_max_retries_exceeded () =
  Eio_main.run (fun _env ->
  let admission = A.create ~default_max_inflight:1 () in
  let scheduler = W.create ~clock:(Eio.Stdenv.clock _env) admission in
  Eio.Switch.run @@ fun sw ->
  let blocker_started, blocker_started_r = Eio.Promise.create () in
  let blocker_never_p, _ = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      ignore (W.try_admission_or_wait scheduler ~tier_id:"test" ~sw
                (fun () ->
                   Eio.Promise.resolve blocker_started_r ();
                   Eio.Promise.await blocker_never_p;
                   "never"));
      `Stop_daemon);
  Eio.Promise.await blocker_started;
  let fast_config = {
    W.backoff = W.Constant 0.001;
    timeout_s = 60.0;
    max_retries = Some 3;
  } in
  match W.try_admission_or_wait scheduler ~tier_id:"test"
          ~wait_config:fast_config ~sw
          (fun () -> "should_not_run") with
  | Error (W.Max_retries_exceeded { tier_id; retries; _ }) ->
      check string "tier_id matches" "test" tier_id;
      check bool "retries <= 3" true (retries <= 3)
  | Error other ->
      fail ("wrong rejection: " ^ Format.asprintf "%a" W.pp_rejection_detail other)
  | Ok _ ->
      fail "should have exceeded retries")

(* {1 Exception propagation preserves release} *)

let test_exception_releases_slot () =
  Eio_main.run (fun _env ->
  let admission = A.create ~default_max_inflight:2 () in
  let scheduler = W.create ~clock:(Eio.Stdenv.clock _env) admission in
  Eio.Switch.run @@ fun sw ->
  (try
     ignore (W.try_admission_or_wait scheduler ~tier_id:"test" ~sw
               (fun () -> failwith "boom"));
     fail "should have raised"
   with Failure msg ->
     check string "exception message preserved" "boom" msg);
  check int "slot released after exception" 0
    (A.current_inflight admission ~tier_id:"test"))

(* {1 Stats observability} *)

let test_stats_no_wait () =
  Eio_main.run (fun _env ->
  let admission = A.create ~default_max_inflight:2 () in
  let scheduler = W.create ~clock:(Eio.Stdenv.clock _env) admission in
  Eio.Switch.run @@ fun sw ->
  (* Immediate admission — no wait stats *)
  ignore (W.try_admission_or_wait scheduler ~tier_id:"test" ~sw
            (fun () -> ()));
  check bool "stats is None (no wait activity)"
    true
    (W.stats scheduler ~tier_id:"test" = None))

let test_stats_after_timeout () =
  Eio_main.run (fun _env ->
  let admission = A.create ~default_max_inflight:1 () in
  let scheduler = W.create ~clock:(Eio.Stdenv.clock _env) admission in
  Eio.Switch.run @@ fun sw ->
  (* Fill slot *)
  let blocker_started, blocker_started_r = Eio.Promise.create () in
  let blocker_never_p, _ = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      ignore (W.try_admission_or_wait scheduler ~tier_id:"test" ~sw
                (fun () ->
                   Eio.Promise.resolve blocker_started_r ();
                   Eio.Promise.await blocker_never_p;
                   "never"));
      `Stop_daemon);
  Eio.Promise.await blocker_started;
  let fast_config = {
    W.backoff = W.Constant 0.001;
    timeout_s = 0.05;
    max_retries = None;
  } in
  ignore (W.try_admission_or_wait scheduler ~tier_id:"test"
            ~wait_config:fast_config ~sw
            (fun () -> ()));
  match W.stats scheduler ~tier_id:"test" with
  | Some s ->
      check bool "total_timeouts >= 1" true (s.total_timeouts >= 1);
      check bool "total_rejected >= 1" true (s.total_rejected >= 1)
  | None ->
      fail "stats should exist after wait activity")

(* {1 on_admission_release manual wake} *)

let test_manual_release_wake () =
  Eio_main.run (fun _env ->
  let admission = A.create ~default_max_inflight:1 () in
  let scheduler = W.create ~clock:(Eio.Stdenv.clock _env) admission in
  Eio.Switch.run @@ fun sw ->
  (* Fill via raw admission, bypassing scheduler *)
  match A.try_acquire admission ~tier_id:"test" with
  | A.Granted _ ->
      let fast_config = {
        W.backoff = W.Constant 0.01;
        timeout_s = 5.0;
        max_retries = None;
      } in
      let waiter_done, waiter_done_r = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
          let r = W.try_admission_or_wait scheduler ~tier_id:"test"
                    ~wait_config:fast_config ~sw
                    (fun () -> "woken") in
          Eio.Promise.resolve waiter_done_r r);
      Eio.Fiber.yield ();
      Eio.Fiber.yield ();
      (* Manual release + notification *)
      A.release admission ~tier_id:"test";
      W.on_admission_release scheduler ~tier_id:"test";
      (match Eio.Promise.await waiter_done with
       | Ok v -> check string "manual wake admitted" "woken" v
       | Error re ->
           fail ("manual wake failed: " ^ Format.asprintf "%a" W.pp_rejection_detail re))
  | A.Capacity_full _ ->
      fail "should have granted on fresh admission")

(* {1 Test suite} *)

let () =
  Alcotest.run "cascade_tier_wait_scheduler" [
    "immediate", [
      test_case "admit when capacity available" `Quick
        test_immediate_admit_simple;
    ];
    "wait", [
      test_case "wait + admitted on release" `Quick
        test_wait_then_admit;
    ];
    "rejection", [
      test_case "timeout expired" `Quick
        test_timeout_expired;
      test_case "max retries exceeded" `Quick
        test_max_retries_exceeded;
    ];
    "safety", [
      test_case "exception releases slot" `Quick
        test_exception_releases_slot;
    ];
    "observability", [
      test_case "stats none when no wait" `Quick
        test_stats_no_wait;
      test_case "stats after timeout" `Quick
        test_stats_after_timeout;
    ];
    "external", [
      test_case "manual release wake" `Quick
        test_manual_release_wake;
    ];
  ]
