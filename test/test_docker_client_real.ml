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
    Keeper_sandbox_plan.of_request
      ~turn_id:1
      ~attempt:0
      ~meta_name:"alice"
      ~cmd:"echo hi"
  with
  | Ok p -> p
  | Error _ -> failwith "test fixture"

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

(* ── Each S function returns the typed placeholder ──────────── *)

let test_run_placeholder () =
  match Docker_client_real.run (sample_plan ()) with
  | Error Docker_client.Cleanup_failed -> ()
  | _ -> fail "expected Cleanup_failed placeholder"

let test_exec_placeholder () =
  match
    Docker_client_real.exec ~container:(sample_container ()) ~cmd:"ls"
  with
  | Error Docker_client.Cleanup_failed -> ()
  | _ -> fail "expected Cleanup_failed placeholder"

let test_ps_query_placeholder () =
  match Docker_client_real.ps_query ~labels:[] with
  | Error Docker_client.Cleanup_failed -> ()
  | _ -> fail "expected Cleanup_failed placeholder"

(* Phase 3b-iv.2.1 — rm is no longer a placeholder; it spawns
   [docker rm -f <name>]. The test environment may or may not have a
   docker daemon, so we only assert that the *typed* error variants
   are surfaced (no exception leakage, no silent success). *)
let test_rm_returns_typed_error () =
  match Docker_client_real.rm (sample_container ()) with
  | Error Docker_client.Daemon_unreachable
  | Error Docker_client.Cleanup_failed -> ()  (* env-dependent path *)
  | Ok () -> fail "unexpected Ok — derived container name should not exist on host"
  | Error Docker_client.Image_pull_failed
  | Error Docker_client.Container_oom
  | Error Docker_client.Exec_timeout
  | Error Docker_client.Probe_format_drift ->
    fail "rm should only surface Daemon_unreachable or Cleanup_failed"

(* ── Functor instantiation works with Real ───────────────────── *)

let test_executor_with_real_returns_placeholder () =
  let r = Real_executor.execute_plan (sample_plan ()) in
  match r with
  | Error Docker_client.Cleanup_failed -> ()
  | _ -> fail "executor with Real placeholder should surface Cleanup_failed"

let () =
  run "Docker_client_real (skeleton)"
    [
      ( "S placeholder",
        [
          test_case "run → Cleanup_failed" `Quick test_run_placeholder;
          test_case "exec → Cleanup_failed" `Quick test_exec_placeholder;
          test_case "ps_query → Cleanup_failed" `Quick test_ps_query_placeholder;
          test_case "rm → typed error (Daemon_unreachable | Cleanup_failed)"
            `Quick
            test_rm_returns_typed_error;
        ] );
      ( "Functor composition",
        [
          test_case "Sandbox_executor.Make (Real) instantiates + forwards placeholder"
            `Quick
            test_executor_with_real_returns_placeholder;
        ] );
    ]
