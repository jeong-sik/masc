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
    ]
