(** RFC-0070 Phase 3c.0 — tests for [Sandbox_executor.Make].

    Demonstrates the Mock + functor composition end-to-end:
    [Sandbox_executor.Make(Docker_client_mock)] satisfies the same
    interface that [Sandbox_executor.Make(Docker_client_real)] will
    in Phase 3b-iv.2. *)

open Alcotest
open Masc_mcp

module Executor = Sandbox_executor.Make (Docker_client_mock)

let setup () = Docker_client_mock.reset ()

let sample_plan ?(turn_id = 1) ?(meta_name = "alice") () =
  match
    Keeper_sandbox_plan.of_request
      ~turn_id
      ~attempt:0
      ~meta_name
      ~cmd:"echo hi"
  with
  | Ok p -> p
  | Error _ -> failwith "test fixture"

let sample_exec_ok =
  Docker_response.{ exit_code = 0; stdout = "ok"; stderr = "" }

(* ── Happy path: Mock injection consumed end-to-end ─────────── *)

let test_execute_plan_happy () =
  setup ();
  let plan = sample_plan () in
  Docker_client_mock.inject_run plan (Ok sample_exec_ok);
  let r = Executor.execute_plan plan in
  (match r with
   | Ok er -> check string "stdout" "ok" er.stdout
   | Error _ -> fail "expected Ok");
  check int "Mock injection consumed (queue empty)"
    0 (Docker_client_mock.pending_calls ())

(* ── Error injection round-trip ───────────────────────────────── *)

let test_execute_plan_daemon_unreachable () =
  setup ();
  let plan = sample_plan () in
  Docker_client_mock.inject_run plan (Error Docker_client.Daemon_unreachable);
  match Executor.execute_plan plan with
  | Error Docker_client.Daemon_unreachable -> ()
  | _ -> fail "expected Error Daemon_unreachable"

let test_execute_plan_image_pull_failed () =
  setup ();
  let plan = sample_plan () in
  Docker_client_mock.inject_run plan (Error Docker_client.Image_pull_failed);
  match Executor.execute_plan plan with
  | Error Docker_client.Image_pull_failed -> ()
  | _ -> fail "expected Error Image_pull_failed"

(* ── No injection: Mock's default Daemon_unreachable surfaces ── *)

let test_execute_plan_no_injection () =
  setup ();
  let plan = sample_plan () in
  match Executor.execute_plan plan with
  | Error Docker_client.Daemon_unreachable -> ()
  | _ -> fail "expected Mock's default Daemon_unreachable miss"

(* ── Determinism: same plan + same injection ⇒ same response ── *)

let test_determinism () =
  setup ();
  let plan = sample_plan () in
  Docker_client_mock.inject_run plan (Ok sample_exec_ok);
  Docker_client_mock.inject_run plan (Ok sample_exec_ok);
  let r1 = Executor.execute_plan plan in
  let r2 = Executor.execute_plan plan in
  match r1, r2 with
  | Ok er1, Ok er2 ->
    check bool "same inputs ⇒ same response"
      true (Docker_response.equal_exec_result er1 er2)
  | _ -> fail "expected both Ok"

(* ── Strict-FIFO interaction with executor: out-of-order plan ── *)

let test_wrong_plan_does_not_consume_injection () =
  setup ();
  let p1 = sample_plan ~turn_id:1 () in
  let p2 = sample_plan ~turn_id:2 () in
  Docker_client_mock.inject_run p1 (Ok sample_exec_ok);
  (* Execute the wrong plan first — should miss, queue stays intact. *)
  let r_miss = Executor.execute_plan p2 in
  (match r_miss with
   | Error Docker_client.Daemon_unreachable -> ()
   | _ -> fail "expected miss");
  check int "queue intact after miss" 1 (Docker_client_mock.pending_calls ());
  (* Now execute the right plan — should match + drain. *)
  let r_ok = Executor.execute_plan p1 in
  match r_ok with
  | Ok _ ->
    check int "queue drained after correct plan"
      0 (Docker_client_mock.pending_calls ())
  | _ -> fail "expected Ok after correct plan"

(* ── Phase 3c.1: execute_plan_with_retry ────────────────────── *)

let retry_default = Keeper_backoff_policy.default_for_sandbox

let test_retry_succeeds_on_last_attempt () =
  setup ();
  let plan = sample_plan () in
  (* 3 injections, first 2 transient, 3rd succeeds. With max_attempts=3
     the retry budget is exactly enough. *)
  Docker_client_mock.inject_run plan (Error Docker_client.Daemon_unreachable);
  Docker_client_mock.inject_run plan (Error Docker_client.Daemon_unreachable);
  Docker_client_mock.inject_run plan (Ok sample_exec_ok);
  let r = Executor.execute_plan_with_retry ~retry:retry_default plan in
  (match r with
   | Ok er -> check string "succeeded on 3rd attempt" "ok" er.stdout
   | Error _ -> fail "expected Ok by 3rd attempt");
  check int "all 3 injections consumed"
    0 (Docker_client_mock.pending_calls ())

let test_retry_exhausts_budget () =
  setup ();
  let plan = sample_plan () in
  Docker_client_mock.inject_run plan (Error Docker_client.Daemon_unreachable);
  Docker_client_mock.inject_run plan (Error Docker_client.Daemon_unreachable);
  Docker_client_mock.inject_run plan (Error Docker_client.Daemon_unreachable);
  let r = Executor.execute_plan_with_retry ~retry:retry_default plan in
  (match r with
   | Error Docker_client.Daemon_unreachable -> ()
   | _ -> fail "expected last Error after exhausting budget");
  check int "all 3 budget calls made"
    0 (Docker_client_mock.pending_calls ())

let test_retry_non_retryable_error_immediate () =
  setup ();
  let plan = sample_plan () in
  Docker_client_mock.inject_run plan (Error Docker_client.Container_oom);
  (* Two more injections that should NEVER be touched, because
     Container_oom is non-retryable in default policy. *)
  Docker_client_mock.inject_run plan (Ok sample_exec_ok);
  Docker_client_mock.inject_run plan (Ok sample_exec_ok);
  let r = Executor.execute_plan_with_retry ~retry:retry_default plan in
  (match r with
   | Error Docker_client.Container_oom -> ()
   | _ -> fail "expected immediate Container_oom");
  check int "only 1 call made; 2 injections remain"
    2 (Docker_client_mock.pending_calls ())

let test_retry_max_attempts_1_disables () =
  setup ();
  let plan = sample_plan () in
  let no_retry =
    Keeper_backoff_policy.make ~max_attempts:1
      ~retryable_errors:[ Docker_client.Daemon_unreachable ]
  in
  Docker_client_mock.inject_run plan (Error Docker_client.Daemon_unreachable);
  Docker_client_mock.inject_run plan (Ok sample_exec_ok);
  let r = Executor.execute_plan_with_retry ~retry:no_retry plan in
  (match r with
   | Error Docker_client.Daemon_unreachable -> ()
   | _ -> fail "expected Error after only 1 attempt");
  check int "1 call made; 1 injection remains"
    1 (Docker_client_mock.pending_calls ())

let test_retry_happy_first_attempt () =
  setup ();
  let plan = sample_plan () in
  Docker_client_mock.inject_run plan (Ok sample_exec_ok);
  let r = Executor.execute_plan_with_retry ~retry:retry_default plan in
  match r with
  | Ok _ -> check int "1 call only" 0 (Docker_client_mock.pending_calls ())
  | _ -> fail "expected Ok on first attempt"

let () =
  run "Sandbox_executor"
    [
      ( "execute_plan",
        [
          test_case "happy path forwards Mock's Ok" `Quick test_execute_plan_happy;
          test_case "Daemon_unreachable round-trip"
            `Quick
            test_execute_plan_daemon_unreachable;
          test_case "Image_pull_failed round-trip"
            `Quick
            test_execute_plan_image_pull_failed;
          test_case "no injection ⇒ default Daemon_unreachable"
            `Quick
            test_execute_plan_no_injection;
        ] );
      ("determinism", [ test_case "same plan + injection ⇒ same response" `Quick test_determinism ]);
      ( "FIFO interaction",
        [
          test_case "wrong plan misses, queue intact"
            `Quick
            test_wrong_plan_does_not_consume_injection;
        ] );
      ( "execute_plan_with_retry",
        [
          test_case "happy on first attempt (no retry needed)"
            `Quick
            test_retry_happy_first_attempt;
          test_case "succeeds on last attempt (transient errors then Ok)"
            `Quick
            test_retry_succeeds_on_last_attempt;
          test_case "exhausts budget (all transient → last Error)"
            `Quick
            test_retry_exhausts_budget;
          test_case "non-retryable error returns immediately"
            `Quick
            test_retry_non_retryable_error_immediate;
          test_case "max_attempts=1 disables retry"
            `Quick
            test_retry_max_attempts_1_disables;
        ] );
    ]
