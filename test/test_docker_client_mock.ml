(** RFC-0070 Phase 3b-iv.1b — tests for [Keeper_docker_client_mock].

    Pins the strict-FIFO + Daemon_unreachable-on-miss contract:
    every call without a matching head injection fails closed.

    Also confirms the mock satisfies the {!Keeper_docker_client.S} module
    type (compile-time check). *)

open Alcotest
open Masc_mcp

(* Compile-time: [Keeper_docker_client_mock] satisfies [Keeper_docker_client.S]. *)
let (_ : (module Keeper_docker_client.S)) = (module Keeper_docker_client_mock)

let sample_plan () =
  match
    Keeper_sandbox_oneshot_plan.of_request
      ~turn_id:1
      ~attempt:0
      ~meta_name:"alice"
      ~cmd:"echo hi"
  with
  | Ok p -> p
  | Error _ -> failwith "test fixture"

let sample_container () =
  Keeper_container_name.derive
    ~algo:Keeper_hash_algo.SHA_256
    ~turn_id:1
    ~attempt:0
    ~suffix:"alice"

let sample_session_plan () =
  match
    Keeper_sandbox_session_plan.of_request
      ~turn_id:9
      ~attempt:0
      ~meta_name:"sess"
      ~image:"ubuntu:22.04"
      ~container_root:"/keeper/sess"
      ~base_path:"/srv/masc"
      ~container_kind:"turn"
      ~network_mode:Keeper_types.Network_none
      ~host_root:"/var/masc/sess"
      ~uid:1
      ~gid:1
      ()
  with
  | Ok p -> p
  | Error _ -> failwith "test fixture: session of_request"

let sample_exec_result =
  Keeper_docker_response.
    { exit_code = 0; stdout = "ok"; stderr = "" }

let sample_ps_record =
  Keeper_docker_response.
    { id = "abc"
    ; name = sample_container ()
    ; status = Running
    ; labels = [ "masc.keeper", "alice" ]
    }

let setup () = Keeper_docker_client_mock.reset ()

(* ── inject_run + run happy path ──────────────────────────────── *)

let test_run_matches_injection () =
  setup ();
  let plan = sample_plan () in
  Keeper_docker_client_mock.inject_run plan (Ok sample_exec_result);
  let r = Keeper_docker_client_mock.run plan in
  (match r with
   | Ok er ->
     check int "exit_code matches" 0 er.exit_code;
     check string "stdout matches" "ok" er.stdout
   | Error _ -> fail "expected Ok response");
  check int "queue drained" 0 (Keeper_docker_client_mock.pending_calls ())

let test_run_unmatched_plan_returns_daemon_unreachable () =
  setup ();
  let p1 = sample_plan () in
  let p2 =
    match
      Keeper_sandbox_oneshot_plan.of_request
        ~turn_id:99 ~attempt:0 ~meta_name:"bob" ~cmd:"x"
    with
    | Ok p -> p
    | Error _ -> failwith "fix"
  in
  Keeper_docker_client_mock.inject_run p1 (Ok sample_exec_result);
  let r = Keeper_docker_client_mock.run p2 in
  (match r with
   | Error Keeper_docker_client.Daemon_unreachable -> ()
   | _ -> fail "expected Error Daemon_unreachable");
  (* Crucially: queue still has the unmatched injection. *)
  check int "unmatched call did NOT consume queued injection"
    1 (Keeper_docker_client_mock.pending_calls ())

let test_run_fifo_order () =
  setup ();
  let p1 = sample_plan () in
  let p2 =
    match
      Keeper_sandbox_oneshot_plan.of_request
        ~turn_id:2 ~attempt:0 ~meta_name:"bob" ~cmd:"y"
    with
    | Ok p -> p
    | Error _ -> failwith "fix"
  in
  Keeper_docker_client_mock.inject_run p1 (Ok sample_exec_result);
  Keeper_docker_client_mock.inject_run p2
    (Ok Keeper_docker_response.{ exit_code = 1; stdout = ""; stderr = "boom" });
  (* Calling out-of-order (p2 first) does NOT match — strict FIFO. *)
  let r_out_of_order = Keeper_docker_client_mock.run p2 in
  (match r_out_of_order with
   | Error Keeper_docker_client.Daemon_unreachable -> ()
   | _ -> fail "expected miss");
  (* Calling in-order works. *)
  let r1 = Keeper_docker_client_mock.run p1 in
  (match r1 with
   | Ok er -> check int "first run, exit 0" 0 er.exit_code
   | Error _ -> fail "expected Ok");
  let r2 = Keeper_docker_client_mock.run p2 in
  match r2 with
  | Ok er -> check int "second run, exit 1" 1 er.exit_code
  | Error _ -> fail "expected Ok"

(* ── exec ────────────────────────────────────────────────────── *)

let test_exec_matches_injection () =
  setup ();
  let c = sample_container () in
  Keeper_docker_client_mock.inject_exec ~container:c ~cmd:"ls -la"
    (Ok sample_exec_result);
  match Keeper_docker_client_mock.exec ~container:c ~cmd:"ls -la" () with
  | Ok er -> check string "stdout" "ok" er.stdout
  | Error _ -> fail "expected Ok"

let test_exec_unmatched_cmd () =
  setup ();
  let c = sample_container () in
  Keeper_docker_client_mock.inject_exec ~container:c ~cmd:"ls -la"
    (Ok sample_exec_result);
  match Keeper_docker_client_mock.exec ~container:c ~cmd:"different cmd" () with
  | Error Keeper_docker_client.Daemon_unreachable -> ()
  | _ -> fail "expected miss on different cmd"

(* Phase 3e (b) — [exec] now takes [?user] / [?workdir]; the mock
   ignores them for matching (key stays [(container, cmd)]). Passing
   them must not change which injection is consumed. *)
let test_exec_ignores_user_workdir_for_matching () =
  setup ();
  let c = sample_container () in
  Keeper_docker_client_mock.inject_exec ~container:c ~cmd:"id" (Ok sample_exec_result);
  match
    Keeper_docker_client_mock.exec ~user:(1000, 1000) ~workdir:"/work" ~container:c ~cmd:"id" ()
  with
  | Ok er -> check string "stdout" "ok" er.stdout
  | Error _ -> fail "expected Ok — user/workdir must not affect matching"

(* Phase 4.1-h — [?stdin] is the same kind of "shape, not match-key"
   field as [?user] / [?workdir]. The mock must accept it and still
   consume the [(container, cmd)] injection unchanged. *)
let test_exec_ignores_stdin_for_matching () =
  setup ();
  let c = sample_container () in
  Keeper_docker_client_mock.inject_exec ~container:c ~cmd:"cat > /tmp/x" (Ok sample_exec_result);
  match
    Keeper_docker_client_mock.exec
      ~stdin:"hello world"
      ~container:c
      ~cmd:"cat > /tmp/x"
      ()
  with
  | Ok er -> check string "stdout" "ok" er.stdout
  | Error _ -> fail "expected Ok — ?stdin must not affect matching"
;;

let test_exec_ignores_all_three_optionals_together () =
  setup ();
  let c = sample_container () in
  Keeper_docker_client_mock.inject_exec ~container:c ~cmd:"tee /tmp/x" (Ok sample_exec_result);
  match
    Keeper_docker_client_mock.exec
      ~user:(1000, 1000)
      ~workdir:"/work"
      ~stdin:"payload"
      ~container:c
      ~cmd:"tee /tmp/x"
      ()
  with
  | Ok _ ->
    check int "injection consumed (1 → 0)" 0 (Keeper_docker_client_mock.pending_calls ())
  | Error _ -> fail "expected Ok — all three optionals must be ignored for matching"
;;

(* ── ps_query ────────────────────────────────────────────────── *)

let test_ps_query_matches () =
  setup ();
  Keeper_docker_client_mock.inject_ps_query
    ~labels:[ "masc.keeper", "alice" ]
    (Ok [ sample_ps_record ]);
  match
    Keeper_docker_client_mock.ps_query ~labels:[ "masc.keeper", "alice" ]
  with
  | Ok records -> check int "1 record returned" 1 (List.length records)
  | Error _ -> fail "expected Ok"

let test_ps_query_empty_response () =
  setup ();
  Keeper_docker_client_mock.inject_ps_query ~labels:[] (Ok []);
  match Keeper_docker_client_mock.ps_query ~labels:[] with
  | Ok [] -> check int "queue drained" 0 (Keeper_docker_client_mock.pending_calls ())
  | _ -> fail "expected Ok []"

(* ── rm ──────────────────────────────────────────────────────── *)

let test_rm_matches () =
  setup ();
  let c = sample_container () in
  Keeper_docker_client_mock.inject_rm c (Ok ());
  match Keeper_docker_client_mock.rm c with
  | Ok () -> ()
  | Error _ -> fail "expected Ok"

let test_rm_error_injection () =
  setup ();
  let c = sample_container () in
  Keeper_docker_client_mock.inject_rm c (Error Keeper_docker_client.Cleanup_failed);
  match Keeper_docker_client_mock.rm c with
  | Error Keeper_docker_client.Cleanup_failed -> ()
  | _ -> fail "expected Cleanup_failed"

(* ── info_security_options (Phase 3e c) ───────────────────────── *)

let test_info_security_options_matches () =
  setup ();
  Keeper_docker_client_mock.inject_info_security_options (Ok [ "name=seccomp"; "name=apparmor" ]);
  match Keeper_docker_client_mock.info_security_options () with
  | Ok opts -> check int "2 options + queue drained" 2 (List.length opts);
    check int "queue drained" 0 (Keeper_docker_client_mock.pending_calls ())
  | Error _ -> fail "expected Ok"

let test_info_security_options_empty_queue () =
  setup ();
  match Keeper_docker_client_mock.info_security_options () with
  | Error Keeper_docker_client.Daemon_unreachable -> ()
  | _ -> fail "empty queue must fail closed with Daemon_unreachable"

let test_info_security_options_error_injection () =
  setup ();
  Keeper_docker_client_mock.inject_info_security_options (Error Keeper_docker_client.Probe_format_drift);
  match Keeper_docker_client_mock.info_security_options () with
  | Error Keeper_docker_client.Probe_format_drift -> ()
  | _ -> fail "expected Probe_format_drift"

(* ── image_present (Phase 3e d) ───────────────────────────────── *)

let test_image_present_matches () =
  setup ();
  Keeper_docker_client_mock.inject_image_present ~image:"alpine:3.20" (Ok ());
  match Keeper_docker_client_mock.image_present ~image:"alpine:3.20" with
  | Ok () -> check int "queue drained" 0 (Keeper_docker_client_mock.pending_calls ())
  | Error _ -> fail "expected Ok"

let test_image_present_wrong_image_miss () =
  setup ();
  Keeper_docker_client_mock.inject_image_present ~image:"alpine:3.20" (Ok ());
  match Keeper_docker_client_mock.image_present ~image:"ubuntu:24.04" with
  | Error Keeper_docker_client.Daemon_unreachable ->
    check int "queue intact on miss" 1 (Keeper_docker_client_mock.pending_calls ())
  | _ -> fail "expected miss on different image"

let test_image_present_error_injection () =
  setup ();
  Keeper_docker_client_mock.inject_image_present ~image:"missing:img" (Error Keeper_docker_client.Image_pull_failed);
  match Keeper_docker_client_mock.image_present ~image:"missing:img" with
  | Error Keeper_docker_client.Image_pull_failed -> ()
  | _ -> fail "expected Image_pull_failed"

(* ── run_detached (Phase 3e a) ────────────────────────────────── *)

let test_run_detached_default_returns_plan_name () =
  setup ();
  let plan = sample_session_plan () in
  match Keeper_docker_client_mock.run_detached plan with
  | Ok name ->
    check bool "default = plan.container_name (no injection needed)" true
      (Keeper_container_name.equal name (Keeper_sandbox_session_plan.container_name plan));
    check int "no queue consumed" 0 (Keeper_docker_client_mock.pending_calls ())
  | Error _ -> fail "expected Ok plan.container_name"

let test_run_detached_error_injection () =
  setup ();
  Keeper_docker_client_mock.inject_run_detached (Error Keeper_docker_client.Daemon_unreachable);
  match Keeper_docker_client_mock.run_detached (sample_session_plan ()) with
  | Error Keeper_docker_client.Daemon_unreachable ->
    check int "injection consumed" 0 (Keeper_docker_client_mock.pending_calls ())
  | _ -> fail "expected the injected Daemon_unreachable"

(* ── reset / pending_calls ────────────────────────────────────── *)

let test_reset_clears_all_queues () =
  setup ();
  let c = sample_container () in
  Keeper_docker_client_mock.inject_run (sample_plan ()) (Ok sample_exec_result);
  Keeper_docker_client_mock.inject_exec ~container:c ~cmd:"x" (Ok sample_exec_result);
  Keeper_docker_client_mock.inject_ps_query ~labels:[] (Ok []);
  Keeper_docker_client_mock.inject_rm c (Ok ());
  Keeper_docker_client_mock.inject_info_security_options (Ok []);
  Keeper_docker_client_mock.inject_image_present ~image:"a:b" (Ok ());
  Keeper_docker_client_mock.inject_run_detached (Ok c);
  check int "7 queued" 7 (Keeper_docker_client_mock.pending_calls ());
  Keeper_docker_client_mock.reset ();
  check int "reset clears everything" 0 (Keeper_docker_client_mock.pending_calls ())

let () =
  run "Keeper_docker_client_mock"
    [
      ( "run",
        [
          test_case "matches injection (FIFO head)" `Quick test_run_matches_injection;
          test_case "unmatched plan → Daemon_unreachable; queue intact"
            `Quick
            test_run_unmatched_plan_returns_daemon_unreachable;
          test_case "strict FIFO — out-of-order misses"
            `Quick
            test_run_fifo_order;
        ] );
      ( "exec",
        [
          test_case "matches" `Quick test_exec_matches_injection;
          test_case "wrong cmd → miss" `Quick test_exec_unmatched_cmd;
          test_case "user/workdir ignored for matching" `Quick
            test_exec_ignores_user_workdir_for_matching;
          test_case "?stdin ignored for matching (Phase 4.1-h)" `Quick
            test_exec_ignores_stdin_for_matching;
          test_case "user + workdir + stdin all ignored for matching" `Quick
            test_exec_ignores_all_three_optionals_together;
        ] );
      ( "ps_query",
        [
          test_case "matches with labels" `Quick test_ps_query_matches;
          test_case "empty labels + empty response" `Quick test_ps_query_empty_response;
        ] );
      ( "rm",
        [
          test_case "matches Ok" `Quick test_rm_matches;
          test_case "Error injection round-trip" `Quick test_rm_error_injection;
        ] );
      ( "info_security_options",
        [
          test_case "matches injection" `Quick test_info_security_options_matches;
          test_case "empty queue → Daemon_unreachable" `Quick
            test_info_security_options_empty_queue;
          test_case "Error injection round-trip" `Quick
            test_info_security_options_error_injection;
        ] );
      ( "image_present",
        [
          test_case "matches injection" `Quick test_image_present_matches;
          test_case "wrong image → miss; queue intact" `Quick
            test_image_present_wrong_image_miss;
          test_case "Error injection round-trip" `Quick
            test_image_present_error_injection;
        ] );
      ( "run_detached",
        [
          test_case "default → plan.container_name (no injection)" `Quick
            test_run_detached_default_returns_plan_name;
          test_case "Error injection overrides default" `Quick
            test_run_detached_error_injection;
        ] );
      ( "lifecycle",
        [ test_case "reset clears all queues" `Quick test_reset_clears_all_queues ] );
    ]
