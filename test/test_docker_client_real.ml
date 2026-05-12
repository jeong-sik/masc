(** RFC-0070 Phase 3b-iv.2.0 — tests for [Docker_client_real] skeleton.

    Pins the typed-placeholder contract: every function returns
    [Error Cleanup_failed]. Critically, this includes a compile-time
    witness that [Docker_client_real] satisfies [Docker_client.S],
    so the [Sandbox_executor.Make] functor accepts both Mock and
    Real interchangeably.

    Sub-phases 3b-iv.2.{1,2,3,4} replace each placeholder one at a
    time; the corresponding test cases below will be retargeted to
    cover the new behaviour as each sub-phase lands. *)

open Alcotest
open Masc_mcp

(* Compile-time witness: Real satisfies S. *)
let (_ : (module Docker_client.S)) = (module Docker_client_real)

(* And it composes with the executor functor (along with Mock from
   Phase 3b-iv.1b). *)
module Real_executor = Sandbox_executor.Make (Docker_client_real)

let sample_plan () =
  match
    Keeper_sandbox_plan.of_request ~turn_id:1 ~attempt:0 ~meta_name:"alice" ~cmd:"echo hi"
  with
  | Ok p -> p
  | Error _ -> failwith "test fixture"
;;

(* Container-name derivation is deterministic in [(turn_id, attempt,
   suffix)], so a literal suffix like ["alice"] could collide with a
   real keeper-derived container on a developer machine and have the
   subsequent [docker rm -f] silently destroy it. Inject PID + a
   nonce into the suffix so the derived SHA-256 is effectively unique
   per test invocation. *)
let () = Random.self_init ()

let sample_container () =
  let pid = Unix.getpid () in
  let nonce = Random.bits () in
  Keeper_container_name.derive
    ~algo:Keeper_hash_algo.SHA_256
    ~turn_id:1
    ~attempt:0
    ~suffix:(Printf.sprintf "test-pid%d-%d" pid nonce)
;;

(* ── Each S function returns the typed placeholder ──────────── *)

(* Phase 3b-iv.2.3 — run is no longer a placeholder. It spawns
   [docker run --rm --name <name> <image> sh -lc <cmd>]. Same typed
   contract as [exec]: either [Ok exec_result] (daemon present) or
   [Error Daemon_unreachable] (daemon / CLI missing). No other
   [sandbox_error] variant is semantically valid for [run]. *)
let test_run_returns_typed_result () =
  match Docker_client_real.run (sample_plan ()) with
  | Ok _ -> () (* daemon present *)
  | Error Docker_client.Daemon_unreachable -> () (* daemon / CLI missing *)
  | Error Docker_client.Exec_timeout -> () (* WEXITED 124 — Process_eio timeout *)
  | Error Docker_client.Cleanup_failed
  | Error Docker_client.Image_pull_failed
  | Error Docker_client.Container_oom
  | Error Docker_client.Probe_format_drift ->
    fail "run should only surface Ok | Daemon_unreachable | Exec_timeout"
;;

(* Phase 3b-iv.2.2 — exec is no longer a placeholder. It spawns
   [docker exec <container> sh -lc <cmd>]. The test environment may
   or may not have a docker daemon, so we only assert the *typed*
   contract: either [Ok exec_result] (daemon present, command ran
   inside container even if it failed) or [Error Daemon_unreachable]
   (no daemon / CLI missing). Other [sandbox_error] variants are
   semantically out of scope for [exec] and must NOT surface. *)
let test_exec_returns_typed_result () =
  match Docker_client_real.exec ~container:(sample_container ()) ~cmd:"echo hi" with
  | Ok _ -> () (* daemon present *)
  | Error Docker_client.Daemon_unreachable -> () (* daemon / CLI missing *)
  | Error Docker_client.Exec_timeout -> () (* WEXITED 124 — Process_eio timeout *)
  | Error Docker_client.Cleanup_failed
  | Error Docker_client.Image_pull_failed
  | Error Docker_client.Container_oom
  | Error Docker_client.Probe_format_drift ->
    fail "exec should only surface Ok | Daemon_unreachable | Exec_timeout"
;;

(* Phase 3b-iv.2.4 — ps_query is no longer a placeholder. It spawns
   [docker ps -a --format '{{json .}}' --filter ...] and parses each
   line. The test environment may or may not have a docker daemon, so
   we only assert the *typed* contract:
   - Ok records (daemon present; list may be empty)
   - Error Daemon_unreachable (daemon / CLI missing)
   - Error Probe_format_drift (docker ps exit non-zero without daemon
     signal — unusual but defined)
   Other sandbox_error variants must NOT surface. *)
let test_ps_query_returns_typed_result () =
  match Docker_client_real.ps_query ~labels:[ "masc.keeper.test", "alice" ] with
  | Ok _ -> ()
  | Error Docker_client.Daemon_unreachable -> ()
  | Error Docker_client.Probe_format_drift -> ()
  | Error Docker_client.Exec_timeout -> () (* WEXITED 124 — Process_eio timeout *)
  | Error Docker_client.Cleanup_failed
  | Error Docker_client.Image_pull_failed
  | Error Docker_client.Container_oom ->
    fail
      "ps_query should only surface Ok | Daemon_unreachable | Probe_format_drift | \
       Exec_timeout"
;;

(* Phase 3b-iv.2.1 — rm is no longer a placeholder; it spawns
   [docker rm -f <name>]. The test environment may or may not have a
   docker daemon, so we only assert that the *typed* error variants
   are surfaced (no exception leakage, no silent success). *)
let test_rm_returns_typed_error () =
  match Docker_client_real.rm (sample_container ()) with
  | Error Docker_client.Daemon_unreachable | Error Docker_client.Cleanup_failed ->
    () (* env-dependent path *)
  | Error Docker_client.Exec_timeout -> () (* WEXITED 124 — Process_eio timeout *)
  | Ok () -> fail "unexpected Ok — derived container name should not exist on host"
  | Error Docker_client.Image_pull_failed
  | Error Docker_client.Container_oom
  | Error Docker_client.Probe_format_drift ->
    fail "rm should only surface Daemon_unreachable | Cleanup_failed | Exec_timeout"
;;

(* ── Functor instantiation works with Real ───────────────────── *)

(* Phase 3b-iv.2.3 — executor.execute_plan calls Real.run, which is
   now wired. Same typed contract as test_run_returns_typed_result. *)
let test_executor_with_real_returns_typed_result () =
  match Real_executor.execute_plan (sample_plan ()) with
  | Ok _ -> ()
  | Error Docker_client.Daemon_unreachable -> ()
  | Error Docker_client.Exec_timeout -> ()
  | Error Docker_client.Cleanup_failed
  | Error Docker_client.Image_pull_failed
  | Error Docker_client.Container_oom
  | Error Docker_client.Probe_format_drift ->
    fail "executor with Real should only surface Ok | Daemon_unreachable | Exec_timeout"
;;

let () =
  run
    "Docker_client_real (Phase 3b-iv.2.4 — all 4 functions wired)"
    [ ( "S placeholder"
      , [ test_case
            "run → Ok | Daemon_unreachable | Exec_timeout"
            `Quick
            test_run_returns_typed_result
        ; test_case
            "exec → Ok | Daemon_unreachable | Exec_timeout"
            `Quick
            test_exec_returns_typed_result
        ; test_case
            "ps_query → Ok | Daemon_unreachable | Probe_format_drift | Exec_timeout"
            `Quick
            test_ps_query_returns_typed_result
        ; test_case
            "rm → Daemon_unreachable | Cleanup_failed | Exec_timeout"
            `Quick
            test_rm_returns_typed_error
        ] )
    ; ( "Functor composition"
      , [ test_case
            "Sandbox_executor.Make (Real) instantiates + forwards placeholder"
            `Quick
            test_executor_with_real_returns_typed_result
        ] )
    ]
;;
