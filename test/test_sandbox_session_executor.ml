(** RFC-0070 Phase 3e (f) — tests for [Sandbox_session_executor.Make].

    Drives [Sandbox_session_executor.Make(Docker_client_mock)] through
    the start → exec → cleanup lifecycle:
    - [start] returns a handle whose [container_name] is the plan's;
      a [run_detached] error injection surfaces typed from [start];
    - [exec] forwards to [D.exec] (matched on container + cmd), a
      non-zero container exit stays an [Ok exec_result], a daemon-level
      error surfaces typed;
    - [cleanup] forwards to [D.rm];
    - same request inputs ⇒ same [container_name] (determinism).
    Hermetic — no daemon, no clock, no Random. *)

open Alcotest
open Masc_mcp

module Session = Sandbox_session_executor.Make (Docker_client_mock)

let setup () = Docker_client_mock.reset ()

let sample_plan ?(turn_id = 7) ?(meta_name = "alice") () =
  match
    Keeper_sandbox_session_plan.of_request
      ~turn_id
      ~attempt:0
      ~meta_name
      ~image:"ubuntu:22.04"
      ~container_root:"/keeper/alice"
      ~base_path:"/srv/masc"
      ~container_kind:"turn"
      ~network_mode:Keeper_types.Network_none
      ~host_root:"/var/masc/alice"
      ~uid:1234
      ~gid:5678
      ()
  with
  | Ok p -> p
  | Error _ -> failwith "test fixture: of_request unexpectedly failed"
;;

let exec_ok = Docker_response.{ exit_code = 0; stdout = "out"; stderr = "" }

let start_or_fail plan =
  match Session.start plan with Ok h -> h | Error _ -> failwith "test: start failed"
;;

(* ── start ──────────────────────────────────────────────────── *)

let test_start_default_wraps_plan_name () =
  setup ();
  let plan = sample_plan () in
  match Session.start plan with
  | Ok handle ->
    check
      bool
      "handle's container_name = plan's"
      true
      (Keeper_container_name.equal
         (Session.container_name handle)
         (Keeper_sandbox_session_plan.container_name plan));
    check int "no Mock queue touched" 0 (Docker_client_mock.pending_calls ())
  | Error _ -> fail "expected Ok from Mock's default run_detached"
;;

let test_start_error_injection_surfaces_typed () =
  setup ();
  let plan = sample_plan () in
  Docker_client_mock.inject_run_detached (Error Docker_client.Daemon_unreachable);
  match Session.start plan with
  | Error Docker_client.Daemon_unreachable -> ()
  | Ok _ -> fail "injected Error should surface from start"
  | Error _ -> fail "wrong error variant"
;;

let test_start_image_pull_failed_surfaces () =
  setup ();
  let plan = sample_plan () in
  Docker_client_mock.inject_run_detached (Error Docker_client.Image_pull_failed);
  match Session.start plan with
  | Error Docker_client.Image_pull_failed -> ()
  | _ -> fail "expected Image_pull_failed from start"
;;

(* ── exec ───────────────────────────────────────────────────── *)

let test_exec_forwards_to_docker_exec () =
  setup ();
  let handle = start_or_fail (sample_plan ()) in
  Docker_client_mock.inject_exec
    ~container:(Session.container_name handle)
    ~cmd:"echo hi"
    (Ok exec_ok);
  (match Session.exec handle ~cmd:"echo hi" with
   | Ok er -> check string "stdout threaded through" "out" er.stdout
   | Error _ -> fail "expected Ok exec_result");
  check int "exec injection consumed" 0 (Docker_client_mock.pending_calls ())
;;

let test_exec_nonzero_exit_is_ok_result () =
  setup ();
  let handle = start_or_fail (sample_plan ()) in
  Docker_client_mock.inject_exec
    ~container:(Session.container_name handle)
    ~cmd:"false"
    (Ok Docker_response.{ exit_code = 1; stdout = ""; stderr = "boom" });
  match Session.exec handle ~cmd:"false" with
  | Ok er ->
    check int "container-command exit code is the result, not an error" 1 er.exit_code
  | Error _ -> fail "non-zero container exit must be Ok, not Error"
;;

let test_exec_daemon_error_surfaces () =
  setup ();
  let handle = start_or_fail (sample_plan ()) in
  Docker_client_mock.inject_exec
    ~container:(Session.container_name handle)
    ~cmd:"echo hi"
    (Error Docker_client.Daemon_unreachable);
  match Session.exec handle ~cmd:"echo hi" with
  | Error Docker_client.Daemon_unreachable -> ()
  | _ -> fail "daemon-level error must surface typed"
;;

let test_exec_no_injection_misses () =
  setup ();
  let handle = start_or_fail (sample_plan ()) in
  match Session.exec handle ~cmd:"echo hi" with
  | Error Docker_client.Daemon_unreachable -> ()
  | _ -> fail "no exec injection ⇒ Mock's default miss"
;;

(* ── cleanup ────────────────────────────────────────────────── *)

let test_cleanup_forwards_to_rm () =
  setup ();
  let handle = start_or_fail (sample_plan ()) in
  Docker_client_mock.inject_rm (Session.container_name handle) (Ok ());
  (match Session.cleanup handle with
   | Ok () -> ()
   | Error _ -> fail "expected Ok ()");
  check int "rm injection consumed" 0 (Docker_client_mock.pending_calls ())
;;

let test_cleanup_error_surfaces () =
  setup ();
  let handle = start_or_fail (sample_plan ()) in
  Docker_client_mock.inject_rm
    (Session.container_name handle)
    (Error Docker_client.Cleanup_failed);
  match Session.cleanup handle with
  | Error Docker_client.Cleanup_failed -> ()
  | _ -> fail "rm error must surface typed"
;;

(* ── full lifecycle ─────────────────────────────────────────── *)

let test_lifecycle_start_exec_cleanup () =
  setup ();
  let handle = start_or_fail (sample_plan ()) in
  let c = Session.container_name handle in
  Docker_client_mock.inject_exec ~container:c ~cmd:"step 1" (Ok exec_ok);
  Docker_client_mock.inject_exec ~container:c ~cmd:"step 2" (Ok exec_ok);
  Docker_client_mock.inject_rm c (Ok ());
  (match Session.exec handle ~cmd:"step 1" with Ok _ -> () | Error _ -> fail "step 1");
  (match Session.exec handle ~cmd:"step 2" with Ok _ -> () | Error _ -> fail "step 2");
  (match Session.cleanup handle with Ok () -> () | Error _ -> fail "cleanup");
  check int "all injections drained in order" 0 (Docker_client_mock.pending_calls ())
;;

(* ── determinism: same plan ⇒ same container_name ───────────── *)

let test_determinism_same_plan_same_name () =
  setup ();
  let n1 = Session.container_name (start_or_fail (sample_plan ())) in
  setup ();
  let n2 = Session.container_name (start_or_fail (sample_plan ())) in
  check
    bool
    "same request inputs ⇒ same container_name"
    true
    (Keeper_container_name.equal n1 n2)
;;

let () =
  run
    "Sandbox_session_executor"
    [ ( "start"
      , [ test_case
            "default ⇒ handle wraps plan's container_name"
            `Quick
            test_start_default_wraps_plan_name
        ; test_case
            "run_detached Error surfaces typed"
            `Quick
            test_start_error_injection_surfaces_typed
        ; test_case "Image_pull_failed surfaces" `Quick test_start_image_pull_failed_surfaces
        ] )
    ; ( "exec"
      , [ test_case
            "forwards to D.exec, threads stdout"
            `Quick
            test_exec_forwards_to_docker_exec
        ; test_case
            "non-zero container exit is Ok result"
            `Quick
            test_exec_nonzero_exit_is_ok_result
        ; test_case "daemon error surfaces typed" `Quick test_exec_daemon_error_surfaces
        ; test_case "no injection ⇒ Mock default miss" `Quick test_exec_no_injection_misses
        ] )
    ; ( "cleanup"
      , [ test_case "forwards to D.rm" `Quick test_cleanup_forwards_to_rm
        ; test_case "rm error surfaces typed" `Quick test_cleanup_error_surfaces
        ] )
    ; ( "lifecycle"
      , [ test_case
            "start → exec×2 → cleanup drains queues"
            `Quick
            test_lifecycle_start_exec_cleanup
        ] )
    ; ( "determinism"
      , [ test_case "same plan ⇒ same container_name" `Quick test_determinism_same_plan_same_name
        ] )
    ]
;;
