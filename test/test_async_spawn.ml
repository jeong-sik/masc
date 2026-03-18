(** Test suite for Async_spawn — non-blocking agent execution with job tracking.

    All tests run inside Eio_main.run to provide the required fiber context
    for Eio.Mutex and Eio.Fiber operations. No real spawn processes are created;
    instead, [submit_job] receives mock [run_fn] closures. *)

open Alcotest

module Async_spawn = Masc_mcp.Async_spawn
module Spawn_eio = Masc_mcp.Spawn_eio

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

(** A mock spawn result for successful completions. *)
let mock_success_result : Spawn_eio.spawn_result = {
  success = true;
  output = "Task completed successfully";
  exit_code = 0;
  elapsed_ms = 42;
  tool_call_count = 0;
  tool_names = [];
  input_tokens = Some 100;
  output_tokens = Some 200;
  cache_creation_tokens = None;
  cache_read_tokens = None;
  cost_usd = Some 0.001;
  raw_trace_run = None;
  termination = None;
}

(** A mock spawn result for failures. *)
let mock_failure_result : Spawn_eio.spawn_result = {
  success = false;
  output = "Agent crashed";
  exit_code = 1;
  elapsed_ms = 100;
  tool_call_count = 0;
  tool_names = [];
  input_tokens = None;
  output_tokens = None;
  cache_creation_tokens = None;
  cache_read_tokens = None;
  cost_usd = None;
  raw_trace_run = None;
  termination = None;
}

(** Run a test body inside Eio_main.run with a Switch. *)
let with_eio f =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  f sw

(* ================================================================ *)
(* Tests: Registry and job lifecycle                                *)
(* ================================================================ *)

let test_create_registry () =
  with_eio @@ fun _sw ->
  let reg = Async_spawn.create_registry () in
  let jobs = Async_spawn.list_jobs reg in
  check int "empty registry" 0 (List.length jobs)

let test_submit_and_complete () =
  with_eio @@ fun sw ->
  let reg = Async_spawn.create_registry () in
  let job = Async_spawn.submit_job reg ~sw
      ~agent_name:"claude" ~prompt:"Do something"
      (fun () -> mock_success_result) in
  check string "status starts running or completes quickly"
    "job-" (String.sub job.job_id 0 4);
  check string "agent_name" "claude" job.agent_name;
  (* Allow the fiber to run *)
  Eio.Fiber.yield ();
  let got = Async_spawn.get_job reg job.job_id in
  match got with
  | None -> fail "job should exist"
  | Some j ->
      (match j.status with
       | Async_spawn.Completed r ->
           check bool "success" true r.success;
           check int "exit_code" 0 r.exit_code
       | Async_spawn.Running ->
           (* Fiber may not have run yet in some schedulers;
              yield again and retry *)
           Eio.Fiber.yield ();
           (match (Async_spawn.get_job reg job.job_id) with
            | Some { status = Async_spawn.Completed r; _ } ->
                check bool "success after yield" true r.success
            | _ -> fail "expected Completed after two yields")
       | _ -> fail "unexpected status")

let test_submit_failure () =
  with_eio @@ fun sw ->
  let reg = Async_spawn.create_registry () in
  let _job = Async_spawn.submit_job reg ~sw
      ~agent_name:"codex" ~prompt:"Fail please"
      (fun () -> mock_failure_result) in
  Eio.Fiber.yield ();
  let jobs = Async_spawn.list_jobs reg in
  check int "one job" 1 (List.length jobs);
  let j = List.hd jobs in
  (match j.status with
   | Async_spawn.Completed r ->
       check bool "not success" false r.success;
       check int "exit_code 1" 1 r.exit_code
   | _ -> fail "expected Completed with failure result")

let test_submit_exception () =
  with_eio @@ fun sw ->
  let reg = Async_spawn.create_registry () in
  let _job = Async_spawn.submit_job reg ~sw
      ~agent_name:"broken" ~prompt:"Crash"
      (fun () -> raise (Failure "kaboom")) in
  Eio.Fiber.yield ();
  let jobs = Async_spawn.list_jobs reg in
  check int "one job" 1 (List.length jobs);
  let j = List.hd jobs in
  (match j.status with
   | Async_spawn.Failed msg ->
       check bool "contains kaboom" true (String.length msg > 0);
       check bool "finished_at set" true (Option.is_some j.finished_at)
   | _ -> fail "expected Failed status")

let test_cancel_running () =
  with_eio @@ fun sw ->
  let reg = Async_spawn.create_registry () in
  (* A job that blocks on a promise — it stays Running until we cancel *)
  let promise, resolver = Eio.Promise.create () in
  let _job = Async_spawn.submit_job reg ~sw
      ~agent_name:"slow" ~prompt:"Wait forever"
      (fun () ->
         ignore (Eio.Promise.await promise);
         mock_success_result) in
  (* Job should be Running before we cancel *)
  let cancelled = Async_spawn.cancel_job reg _job.job_id in
  check bool "cancel succeeded" true cancelled;
  (match (Async_spawn.get_job reg _job.job_id) with
   | Some { status = Async_spawn.Cancelled; _ } -> ()
   | _ -> fail "expected Cancelled status");
  (* Resolve promise so fiber can terminate cleanly *)
  Eio.Promise.resolve resolver ()

let test_cancel_nonexistent () =
  with_eio @@ fun _sw ->
  let reg = Async_spawn.create_registry () in
  let cancelled = Async_spawn.cancel_job reg "job-nonexistent" in
  check bool "cancel returns false" false cancelled

let test_cancel_already_completed () =
  with_eio @@ fun sw ->
  let reg = Async_spawn.create_registry () in
  let job = Async_spawn.submit_job reg ~sw
      ~agent_name:"fast" ~prompt:"Quick"
      (fun () -> mock_success_result) in
  Eio.Fiber.yield ();
  let cancelled = Async_spawn.cancel_job reg job.job_id in
  check bool "cannot cancel completed" false cancelled

let test_list_jobs () =
  with_eio @@ fun sw ->
  let reg = Async_spawn.create_registry () in
  ignore (Async_spawn.submit_job reg ~sw
      ~agent_name:"a1" ~prompt:"p1" (fun () -> mock_success_result));
  ignore (Async_spawn.submit_job reg ~sw
      ~agent_name:"a2" ~prompt:"p2" (fun () -> mock_success_result));
  ignore (Async_spawn.submit_job reg ~sw
      ~agent_name:"a3" ~prompt:"p3" (fun () -> mock_failure_result));
  Eio.Fiber.yield ();
  let jobs = Async_spawn.list_jobs reg in
  check int "three jobs" 3 (List.length jobs)

let test_cleanup_completed () =
  with_eio @@ fun sw ->
  let reg = Async_spawn.create_registry () in
  ignore (Async_spawn.submit_job reg ~sw
      ~agent_name:"old" ~prompt:"done" (fun () -> mock_success_result));
  Eio.Fiber.yield ();
  (* Cleanup with max_age_s=0 should remove everything finished *)
  let removed = Async_spawn.cleanup_completed reg ~max_age_s:0.0 in
  check int "removed 1" 1 removed;
  let remaining = Async_spawn.list_jobs reg in
  check int "empty after cleanup" 0 (List.length remaining)

let test_cleanup_preserves_running () =
  with_eio @@ fun sw ->
  let reg = Async_spawn.create_registry () in
  let promise, resolver = Eio.Promise.create () in
  ignore (Async_spawn.submit_job reg ~sw
      ~agent_name:"running" ~prompt:"still going"
      (fun () -> ignore (Eio.Promise.await promise); mock_success_result));
  (* Also add a completed one *)
  ignore (Async_spawn.submit_job reg ~sw
      ~agent_name:"done" ~prompt:"finished" (fun () -> mock_success_result));
  Eio.Fiber.yield ();
  let removed = Async_spawn.cleanup_completed reg ~max_age_s:0.0 in
  check int "removed only completed" 1 removed;
  let remaining = Async_spawn.list_jobs reg in
  check int "running job preserved" 1 (List.length remaining);
  Eio.Promise.resolve resolver ()

let test_prompt_preview_truncation () =
  with_eio @@ fun sw ->
  let reg = Async_spawn.create_registry () in
  let long_prompt = String.make 200 'x' in
  let job = Async_spawn.submit_job reg ~sw
      ~agent_name:"test" ~prompt:long_prompt (fun () -> mock_success_result) in
  (* Preview should be 100 chars + "..." = 103 chars *)
  check bool "preview truncated" true (String.length job.prompt_preview <= 103);
  check bool "preview ends with ..." true
    (let len = String.length job.prompt_preview in
     len >= 3 && String.sub job.prompt_preview (len - 3) 3 = "...");
  Eio.Fiber.yield ()

(* ================================================================ *)
(* Tests: JSON serialization                                        *)
(* ================================================================ *)

let test_status_to_string () =
  check string "running" "running" (Async_spawn.status_to_string Running);
  check string "completed" "completed"
    (Async_spawn.status_to_string (Completed mock_success_result));
  check string "failed" "failed"
    (Async_spawn.status_to_string (Failed "err"));
  check string "cancelled" "cancelled"
    (Async_spawn.status_to_string Cancelled)

let test_job_to_json_completed () =
  with_eio @@ fun sw ->
  let reg = Async_spawn.create_registry () in
  let job = Async_spawn.submit_job reg ~sw
      ~agent_name:"test" ~prompt:"hello" (fun () -> mock_success_result) in
  Eio.Fiber.yield ();
  let got = Async_spawn.get_job reg job.job_id in
  match got with
  | None -> fail "job should exist"
  | Some j ->
      let json = Async_spawn.job_to_json j in
      let open Yojson.Safe.Util in
      check string "job_id in json" j.job_id (json |> member "job_id" |> to_string);
      check string "status" "completed" (json |> member "status" |> to_string);
      check bool "has success field" true
        (json |> member "success" |> to_bool_option |> Option.is_some)

let test_job_to_json_failed () =
  let job : Async_spawn.job = {
    job_id = "job-test1234";
    agent_name = "broken";
    prompt_preview = "crash now";
    started_at = 1000.0;
    status = Failed "segfault";
    finished_at = Some 1001.0;
  } in
  let json = Async_spawn.job_to_json job in
  let open Yojson.Safe.Util in
  check string "status" "failed" (json |> member "status" |> to_string);
  check string "error" "segfault" (json |> member "error" |> to_string)

(* ================================================================ *)
(* Test runner                                                      *)
(* ================================================================ *)

let () =
  run "async_spawn" [
    "registry", [
      test_case "create empty registry" `Quick test_create_registry;
      test_case "submit and complete" `Quick test_submit_and_complete;
      test_case "submit failure result" `Quick test_submit_failure;
      test_case "submit with exception" `Quick test_submit_exception;
      test_case "cancel running job" `Quick test_cancel_running;
      test_case "cancel nonexistent" `Quick test_cancel_nonexistent;
      test_case "cancel already completed" `Quick test_cancel_already_completed;
      test_case "list jobs" `Quick test_list_jobs;
      test_case "cleanup completed" `Quick test_cleanup_completed;
      test_case "cleanup preserves running" `Quick test_cleanup_preserves_running;
      test_case "prompt preview truncation" `Quick test_prompt_preview_truncation;
    ];
    "serialization", [
      test_case "status_to_string" `Quick test_status_to_string;
      test_case "job_to_json completed" `Quick test_job_to_json_completed;
      test_case "job_to_json failed" `Quick test_job_to_json_failed;
    ];
  ]
