(** Coverage tests for Tool_task *)

open Masc_mcp

let () = Random.self_init ()

let () = Printf.printf "\n=== Tool_task Coverage Tests ===\n"

let with_env name value_opt f =
  let original = Sys.getenv_opt name in
  let restore () =
    match original with
    | Some value -> Unix.putenv name value
    | None -> Unix.putenv name ""
  in
  Fun.protect
    ~finally:restore
    (fun () ->
      (match value_opt with
       | Some value -> Unix.putenv name value
       | None -> Unix.putenv name "");
      f ())

let with_isolated_runtime_env f =
  with_env "MASC_BASE_PATH" None (fun () ->
    with_env "MASC_BASE_PATH_INPUT" None (fun () ->
      with_env "MASC_STORAGE_TYPE" None (fun () ->
        with_env "MASC_POSTGRES_URL" None (fun () ->
          with_env "DATABASE_URL" None (fun () ->
            with_env "SUPABASE_DB_URL" None (fun () ->
              with_env "SB_PG_URL" None f))))))

(* Test helper *)
let test name f =
  try
    Eio_main.run @@ (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      with_isolated_runtime_env f);
    Printf.printf "✓ %s passed\n" name
  with e ->
    Printf.printf "✗ %s FAILED: %s\n" name (Printexc.to_string e);
    exit 1

(* Create test context *)
let test_counter = ref 0
let make_test_ctx_with_agent agent_name =
  incr test_counter;
  let tmp = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-task-test-%d-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) !test_counter) in
  Unix.mkdir tmp 0o755;
  let config = Room.default_config tmp in
  let _ = Room.init config ~agent_name:(Some agent_name) in
  { Tool_task.config; agent_name; sw = None }

let make_test_ctx () = make_test_ctx_with_agent "test-agent"

let make_temp_dir prefix =
  incr test_counter;
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix
       (int_of_float (Unix.gettimeofday () *. 1000.0)) !test_counter) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let str_contains s substring =
  let len_s = String.length s in
  let len_sub = String.length substring in
  if len_sub > len_s then false
  else
    let rec loop i =
      if i > len_s - len_sub then false
      else if String.sub s i len_sub = substring then true
      else loop (i + 1)
    in
    loop 0

(* Test dispatch returns None for unknown tool *)
let () = test "dispatch_unknown_tool" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  assert (Tool_task.dispatch ctx ~name:"unknown_tool" ~args = None)
)

(* Test dispatch add_task *)
let () = test "dispatch_add_task" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("title", `String "Test task"); ("priority", `Int 2)] in
  match Tool_task.dispatch ctx ~name:"masc_add_task" ~args with
  | Some (success, _result) -> assert success
  | None -> failwith "dispatch returned None"
)

(* Test dispatch tasks *)
let () = test "dispatch_tasks" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_task.dispatch ctx ~name:"masc_tasks" ~args with
  | Some (success, _result) -> assert success
  | None -> failwith "dispatch returned None"
)

let () = test "masc_oas_bridge_runs_without_eio_env" (fun () ->
  match Masc_eio_env.get_opt () with
  | Some _ ->
    failwith
      "masc_oas_bridge_runs_without_eio_env requires Masc_eio_env.get_opt () = None before calling run_safe"
  | None ->
    match Masc_oas_bridge.run_safe ~timeout_s:0.1 (fun () -> Ok "ok") with
    | Ok "ok" -> ()
    | Ok other -> failwith ("unexpected result: " ^ other)
    | Error err -> failwith (Oas.Error.to_string err)
)

(* Test dispatch transition claim *)
let () = test "dispatch_transition_claim" (fun () ->
  let ctx = make_test_ctx () in
  (* First add a task *)
  let _ = Tool_task.handle_add_task ctx (`Assoc [("title", `String "Claim test")]) in
  let args = `Assoc [("task_id", `String "task-001"); ("action", `String "claim")] in
  match Tool_task.dispatch ctx ~name:"masc_transition" ~args with
  | Some (_success, _result) -> () (* May fail if task doesn't exist *)
  | None -> failwith "dispatch returned None"
)

(* Test dispatch claim_next *)
let () = test "dispatch_claim_next" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_task.dispatch ctx ~name:"masc_claim_next" ~args with
  | Some (_success, _result) -> ()
  | None -> failwith "dispatch returned None"
)

(* Test handle_done triggers calibration logging (#3164) *)
let () = test "handle_done_records_calibration_verdict" (fun () ->
  let ctx = make_test_ctx () in
  (* Setup: add task, claim it *)
  let _ = Tool_task.handle_add_task ctx
    (`Assoc [("title", `String "Calibration test task")]) in
  let _ = Tool_task.handle_claim ctx
    (`Assoc [("task_id", `String "task-001")]) in
  let verdict_dir = make_temp_dir "masc-verdict-test" in
  Eval_calibration.set_store_for_testing ~base_dir:verdict_dir;
  (* Trigger done with short notes (< 10 chars) to hit length gate *)
  let (success, result) = Tool_task.handle_done ctx
    (`Assoc [
      ("task_id", `String "task-001");
      ("notes", `String "x")
    ]) in
  assert (not success);
  assert (str_contains result "Completion rejected by anti-rationalization gate");
  (* Verify: verdict was recorded in the store *)
  let store = Eval_calibration.get_store () in
  let records = Dated_jsonl.read_recent store 10 in
  assert (List.length records >= 1);
  let first = List.hd records in
  let record_type = Yojson.Safe.Util.(first |> member "record_type" |> to_string) in
  let gate = Yojson.Safe.Util.(first |> member "gate" |> to_string) in
  let verdict = Yojson.Safe.Util.(first |> member "verdict" |> to_string) in
  assert (record_type = "verdict");
  assert (gate = "length");
  assert (str_contains verdict "reject");
  Printf.printf "  (verdict=%s gate=%s)\n" verdict gate;
  Eval_calibration.reset_store_for_testing ()
)

let () = test "handle_done_records_approved_calibration_verdict" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Tool_task.handle_add_task ctx
    (`Assoc [("title", `String "Approved calibration task")]) in
  let _ = Tool_task.handle_claim ctx
    (`Assoc [("task_id", `String "task-001")]) in
  let verdict_dir = make_temp_dir "masc-verdict-approve-test" in
  Eval_calibration.set_store_for_testing ~base_dir:verdict_dir;
  let success, result = Tool_task.handle_done ctx
    (`Assoc [
      ("task_id", `String "task-001");
      ("notes", `String "Implemented the calibration coverage path, verified the JSONL verdict store, and completed the task cleanly.")
    ]) in
  if not success then failwith result;
  let store = Eval_calibration.get_store () in
  let records = Dated_jsonl.read_recent store 10 in
  assert (List.length records >= 1);
  let first = List.hd records in
  let verdict = Yojson.Safe.Util.(first |> member "verdict" |> to_string) in
  assert (verdict = "approve");
  Eval_calibration.reset_store_for_testing ()
)

let () = test "handle_transition_respects_completion_contract_and_records_custom_evaluator" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Tool_task.handle_add_task ctx
    (`Assoc [("title", `String "Contract calibration task")]) in
  let _ = Tool_task.handle_claim ctx
    (`Assoc [("task_id", `String "task-001")]) in
  let verdict_dir = make_temp_dir "masc-verdict-contract-test" in
  Eval_calibration.set_store_for_testing ~base_dir:verdict_dir;
  let success, result = Tool_task.handle_transition ctx
    (`Assoc [
      ("task_id", `String "task-001");
      ("action", `String "done");
      ("notes", `String "Applied the fix to the login path.");
      ("completion_contract", `List [ `String "test coverage"; `String "migration" ]);
      ("evaluator_cascade", `String "glm:auto");
    ]) in
  assert (not success);
  assert (str_contains result "completion contract not satisfied");
  let store = Eval_calibration.get_store () in
  let records = Dated_jsonl.read_recent store 10 in
  assert (List.length records >= 1);
  let first = List.hd records in
  let gate = Yojson.Safe.Util.(first |> member "gate" |> to_string) in
  let evaluator_cascade =
    Yojson.Safe.Util.(first |> member "evaluator_cascade" |> to_string)
  in
  assert (gate = "contract");
  assert (evaluator_cascade = "glm:auto");
  Eval_calibration.reset_store_for_testing ()
)

let () = test "handle_add_task_persists_contract" (fun () ->
  let ctx = make_test_ctx () in
  let (success, result) =
    Tool_task.handle_add_task ctx
      (`Assoc
        [
          ("title", `String "Strict task");
          ( "contract",
            `Assoc
              [
                ("strict", `Bool true);
                ( "completion_contract",
                  `List [ `String "deliverable-ready" ] );
                ("required_evidence", `List [ `String "run_deliverable" ]);
              ] );
        ])
  in
  if not success then failwith result;
  match Room.get_tasks_raw ctx.config with
  | [ task ] -> (
      match task.contract with
      | Some contract ->
          assert contract.strict;
          assert (contract.required_evidence = [ "run_deliverable" ])
      | None -> failwith "expected persisted task contract")
  | _ -> failwith "expected exactly one task"
)

let () = test "handle_done_uses_persisted_contract_gate" (fun () ->
  (* Task_contract_gate removed — persisted_contract_rejection always returns
     None, so handle_done succeeds immediately without the gate rejection.
     Verify that completion works without the gate. *)
  let ctx = make_test_ctx () in
  let _ =
    Tool_task.handle_add_task ctx
      (`Assoc
        [
          ("title", `String "Strict deliverable task");
          ( "contract",
            `Assoc
              [
                ("strict", `Bool true);
                ( "completion_contract",
                  `List [ `String "deliverable-ready" ] );
                ("required_evidence", `List [ `String "run_deliverable" ]);
              ] );
        ])
  in
  let _ = Tool_task.handle_claim ctx (`Assoc [ ("task_id", `String "task-001") ]) in
  let success_done, result_done =
    Tool_task.handle_done ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("notes", `String "deliverable-ready");
        ])
  in
  (* With gate removed, completion succeeds directly *)
  if not success_done then failwith result_done
)

let () = test "handle_transition_release_requires_handoff_for_strict_task" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Tool_task.handle_add_task ctx
      (`Assoc
        [
          ("title", `String "Strict release task");
          ("contract", `Assoc [ ("strict", `Bool true) ]);
        ])
  in
  let _ = Tool_task.handle_claim ctx (`Assoc [ ("task_id", `String "task-001") ]) in
  let success_missing, result_missing =
    Tool_task.handle_transition ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "release");
        ])
  in
  assert (not success_missing);
  assert (str_contains result_missing "handoff_context.summary");
  let success_release, result_release =
    Tool_task.handle_transition ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "release");
          ( "handoff_context",
            `Assoc
              [
                ("summary", `String "blocked on integration fixture");
                ("next_step", `String "reproduce with real fixture");
                ( "evidence_refs",
                  `List [ `String "task-001"; `String "session:test" ] );
              ] );
        ])
  in
  if not success_release then failwith result_release;
  match Room.get_tasks_raw ctx.config with
  | [ task ] -> (
      match task.handoff_context with
      | Some handoff_context ->
          assert (handoff_context.summary = "blocked on integration fixture");
          assert (handoff_context.updated_by = Some "test-agent")
      | None -> failwith "expected persisted handoff_context")
  | _ -> failwith "expected exactly one task"
)

let () = test "handle_claim_sets_planning_current_task" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Tool_task.handle_add_task ctx (`Assoc [("title", `String "Claim direct")]) in
  let (success, _result) =
    Tool_task.handle_claim ctx (`Assoc [("task_id", `String "task-001")])
  in
  assert success;
  assert (Planning_eio.get_current_task ctx.config = Some "task-001")
)

let () = test "handle_claim_appends_preset_warning_only_on_success" (fun () ->
  let agent_name = "test-agent" in
  let ctx = make_test_ctx_with_agent agent_name in
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Keeper_tool_policy.init_policy_config ~base_path));
  (match
     Room.update_agent_r ctx.config ~agent_name
       ~capabilities:[ "preset:minimal" ] ()
   with
  | Ok _ -> ()
  | Error e -> failwith (Types.masc_error_to_string e));
  let _ =
    Tool_task.handle_add_task ctx
      (`Assoc
        [
          ("title", `String "Needs social");
          ("required_preset", `String "social");
        ])
  in
  let success, result =
    Tool_task.handle_claim ctx (`Assoc [ ("task_id", `String "task-001") ])
  in
  assert success;
  assert (str_contains result "preset_mismatch")
)

let () = test "handle_claim_skips_preset_warning_on_failed_claim" (fun () ->
  let agent_name = "test-agent" in
  let ctx = make_test_ctx_with_agent agent_name in
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Keeper_tool_policy.init_policy_config ~base_path));
  (match
     Room.update_agent_r ctx.config ~agent_name
       ~capabilities:[ "preset:minimal" ] ()
   with
  | Ok _ -> ()
  | Error e -> failwith (Types.masc_error_to_string e));
  let _ =
    Tool_task.handle_add_task ctx
      (`Assoc
        [
          ("title", `String "Needs social");
          ("required_preset", `String "social");
        ])
  in
  let _ = Room.join ctx.config ~agent_name:"other-agent" ~capabilities:[] () in
  (match Room.claim_task_r ctx.config ~agent_name:"other-agent" ~task_id:"task-001" () with
  | Ok _ -> ()
  | Error e -> failwith (Types.masc_error_to_string e));
  let success, result =
    Tool_task.handle_claim ctx (`Assoc [ ("task_id", `String "task-001") ])
  in
  assert (not success);
  assert (not (str_contains result "preset_mismatch"))
)

let () = test "handle_claim_next_sets_planning_current_task" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Tool_task.handle_add_task ctx (`Assoc [("title", `String "Claim next")]) in
  let (success, _result) = Tool_task.handle_claim_next ctx (`Assoc []) in
  assert success;
  assert (Planning_eio.get_current_task ctx.config = Some "task-001")
)

let () = test "handle_claim_next_prefers_live_keeper_preset" (fun () ->
  let agent_name = "keeper-social-sync-agent" in
  let keeper_name = "social-sync" in
  let ctx = make_test_ctx_with_agent agent_name in
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Keeper_tool_policy.init_policy_config ~base_path));
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String agent_name);
            ("trace_id", `String "trace-social-sync");
            ( "tool_access",
              `Assoc
                [
                  ("kind", `String "preset");
                  ("preset", `String "social");
                ] );
          ])
    with
    | Ok meta -> meta
    | Error e -> failwith ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true ctx.config initial_meta with
  | Ok () -> ()
  | Error e -> failwith ("write_meta failed: " ^ e));
  (match
     Room.update_agent_r ctx.config ~agent_name
       ~capabilities:[ "keeper"; "preset:minimal" ] ()
   with
  | Ok _ -> ()
  | Error e -> failwith (Types.masc_error_to_string e));
  let _ =
    Tool_task.handle_add_task ctx
      (`Assoc
        [
          ("title", `String "Needs social");
          ("required_preset", `String "social");
        ])
  in
  let success, result = Tool_task.handle_claim_next ctx (`Assoc []) in
  assert success;
  match Room.get_tasks_raw ctx.config with
  | [ task ] -> (
      match task.task_status with
      | Types.Claimed { assignee; _ } -> assert (assignee = agent_name)
      | _ -> failwith ("expected task to be claimed: " ^ result))
  | _ -> failwith ("expected exactly one task: " ^ result)
)

let () = test "transition_claim_leaves_planning_current_task_unset" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Tool_task.handle_add_task ctx (`Assoc [("title", `String "Transition claim")]) in
  let (success, _result) =
    Tool_task.handle_transition ctx
      (`Assoc [("task_id", `String "task-001"); ("action", `String "claim")])
  in
  assert success;
  assert (Planning_eio.get_current_task ctx.config = None)
)

(* Test handle_done returns owner guidance when another agent owns the task *)
let () = test "handle_done_owned_by_other_guidance" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Tool_task.handle_add_task ctx (`Assoc [("title", `String "Done test")]) in
  let _ = Room.claim_task ctx.config ~agent_name:"other-agent" ~task_id:"task-001" in
  let success, result =
    Tool_task.handle_done ctx (`Assoc [("task_id", `String "task-001"); ("notes", `String "")])
  in
  assert (not success);
  assert (str_contains result "currently owned by other-agent")
)

(* Test handle_done on todo task recommends claim/start first *)
let () = test "handle_done_todo_guidance" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Tool_task.handle_add_task ctx (`Assoc [("title", `String "Todo test")]) in
  let success, result =
    Tool_task.handle_done ctx (`Assoc [("task_id", `String "task-001"); ("notes", `String "")])
  in
  assert (not success);
  assert (str_contains result "Claim/start it first")
)

(* Test handle_done reports already-done guidance instead of generic not-claimed *)
let () = test "handle_done_already_done_guidance" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Tool_task.handle_add_task ctx (`Assoc [("title", `String "Done test")]) in
  let _ = Room.claim_task ctx.config ~agent_name:"other-agent" ~task_id:"task-001" in
  let _ = Room.complete_task_r ctx.config ~agent_name:"other-agent" ~task_id:"task-001" ~notes:"done" in
  let success, result =
    Tool_task.handle_done ctx (`Assoc [("task_id", `String "task-001"); ("notes", `String "")])
  in
  assert (not success);
  assert (str_contains result "already done by other-agent")
)

(* Test handle_done reports cancelled-task guidance instead of generic not-claimed *)
let () = test "handle_done_cancelled_guidance" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Tool_task.handle_add_task ctx (`Assoc [("title", `String "Cancelled test")]) in
  let _ = Room.cancel_task_r ctx.config ~agent_name:"test-agent" ~task_id:"task-001" ~reason:"stop" in
  let success, result =
    Tool_task.handle_done ctx (`Assoc [("task_id", `String "task-001"); ("notes", `String "")])
  in
  assert (not success);
  assert (str_contains result "was cancelled by test-agent")
)

(* Test dispatch transition release *)
let () = test "dispatch_transition_release" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("task_id", `String "task-001"); ("action", `String "release")] in
  match Tool_task.dispatch ctx ~name:"masc_transition" ~args with
  | Some (_success, _result) -> ()
  | None -> failwith "dispatch returned None"
)

(* Test dispatch transition *)
let () = test "dispatch_transition" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("task_id", `String "task-001"); ("action", `String "start")] in
  match Tool_task.dispatch ctx ~name:"masc_transition" ~args with
  | Some (_success, _result) -> ()
  | None -> failwith "dispatch returned None"
)

(* Test dispatch update_priority *)
let () = test "dispatch_update_priority" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("task_id", `String "task-001"); ("priority", `Int 1)] in
  match Tool_task.dispatch ctx ~name:"masc_update_priority" ~args with
  | Some (_success, _result) -> ()
  | None -> failwith "dispatch returned None"
)

(* Test dispatch task_history *)
let () = test "dispatch_task_history" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("task_id", `String "task-001")] in
  match Tool_task.dispatch ctx ~name:"masc_task_history" ~args with
  | Some (success, _result) -> assert success
  | None -> failwith "dispatch returned None"
)

(* Test dispatch archive_view *)
let () = test "dispatch_archive_view" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("limit", `Int 10)] in
  match Tool_task.dispatch ctx ~name:"masc_archive_view" ~args with
  | Some (success, _result) -> assert success
  | None -> failwith "dispatch returned None"
)

(* Test batch_add_tasks *)
let () = test "handle_batch_add_tasks" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [
    ("tasks", `List [
      `Assoc [("title", `String "Task 1"); ("priority", `Int 1)];
      `Assoc [("title", `String "Task 2"); ("priority", `Int 2)];
    ])
  ] in
  let (success, _) = Tool_task.handle_batch_add_tasks ctx args in
  assert success
)

(* Test helper functions *)
let () = test "get_string_present" (fun () ->
  let args = `Assoc [("key", `String "value")] in
  assert (Tool_args.get_string args "key" "default" = "value")
)

let () = test "get_string_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_string args "key" "default" = "default")
)

let () = test "get_int_present" (fun () ->
  let args = `Assoc [("key", `Int 42)] in
  assert (Tool_args.get_int args "key" 0 = 42)
)

let () = test "get_int_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_int args "key" 99 = 99)
)

let () = test "get_int_opt_present" (fun () ->
  let args = `Assoc [("key", `Int 42)] in
  assert (Tool_args.get_int_opt args "key" = Some 42)
)

let () = test "get_int_opt_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_int_opt args "key" = None)
)

(* ================================================================ *)
(* verdict_recorded SSE payload contract                             *)
(*                                                                   *)
(* The payload is built by Tool_task.build_verdict_sse_payload —     *)
(* a pure helper — so dashboard subscribers depend on a stable       *)
(* JSON shape. The cross_model bool must match Eval_calibration's    *)
(* inclusion rule (both cascades non-empty AND distinct).            *)
(* ================================================================ *)

let make_review_request () : Anti_rationalization.review_request =
  { task_title = "Fix login bug";
    task_description = "desc";
    completion_notes = "notes";
    agent_name = "dreamer" }

let make_review_result
    ?(verdict = Anti_rationalization.Approve)
    ?(evaluator_cascade = "verifier")
    ?generator_cascade
    ?(gate = Anti_rationalization.Structured_tool)
    ?fallback_reason
    () : Anti_rationalization.review_result =
  { verdict; evaluator_cascade; generator_cascade; gate; fallback_reason }

let payload_member key (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields -> List.assoc "payload" fields |> (function
      | `Assoc payload_fields -> List.assoc key payload_fields
      | _ -> failwith "payload is not an object")
  | _ -> failwith "top-level is not an object"

let () = test "build_verdict_sse_payload: distinct cascades = cross_model true" (fun () ->
  let req = make_review_request () in
  let result =
    make_review_result
      ~evaluator_cascade:"verifier"
      ~generator_cascade:"keeper_unified"
      () in
  let json = Tool_task.build_verdict_sse_payload
    ~now:1234567890.0 ~task_id:"t1" ~req ~result in
  assert (payload_member "cross_model" json = `Bool true);
  assert (payload_member "generator_cascade" json = `String "keeper_unified");
  assert (payload_member "evaluator_cascade" json = `String "verifier");
  assert (payload_member "task_id" json = `String "t1")
)

let () = test "build_verdict_sse_payload: same cascade = cross_model false" (fun () ->
  let req = make_review_request () in
  let result =
    make_review_result
      ~evaluator_cascade:"verifier"
      ~generator_cascade:"verifier"
      () in
  let json = Tool_task.build_verdict_sse_payload
    ~now:1234567890.0 ~task_id:"t2" ~req ~result in
  assert (payload_member "cross_model" json = `Bool false);
  assert (payload_member "generator_cascade" json = `String "verifier")
)

let () = test "build_verdict_sse_payload: no generator = cross_model false + null" (fun () ->
  let req = make_review_request () in
  let result =
    make_review_result ~evaluator_cascade:"verifier" () in
  let json = Tool_task.build_verdict_sse_payload
    ~now:1234567890.0 ~task_id:"t3" ~req ~result in
  assert (payload_member "cross_model" json = `Bool false);
  assert (payload_member "generator_cascade" json = `Null)
)

let () = test "build_verdict_sse_payload: empty generator string = cross_model false" (fun () ->
  (* Defensive: align with Eval_calibration which excludes empty
     strings from the denominator. Without this guard SSE and stats
     would disagree when a cascade is empty. *)
  let req = make_review_request () in
  let result =
    make_review_result
      ~evaluator_cascade:"verifier"
      ~generator_cascade:""
      () in
  let json = Tool_task.build_verdict_sse_payload
    ~now:1234567890.0 ~task_id:"t4" ~req ~result in
  assert (payload_member "cross_model" json = `Bool false);
  assert (payload_member "generator_cascade" json = `String "")
)

let () = test "build_verdict_sse_payload: empty evaluator string = cross_model false" (fun () ->
  let req = make_review_request () in
  let result =
    make_review_result
      ~evaluator_cascade:""
      ~generator_cascade:"keeper_unified"
      () in
  let json = Tool_task.build_verdict_sse_payload
    ~now:1234567890.0 ~task_id:"t5" ~req ~result in
  assert (payload_member "cross_model" json = `Bool false)
)

let () = test "build_verdict_sse_payload: fallback_reason serialized" (fun () ->
  let req = make_review_request () in
  let result =
    make_review_result
      ~fallback_reason:"llm timeout"
      ~gate:Anti_rationalization.Fallback
      () in
  let json = Tool_task.build_verdict_sse_payload
    ~now:1234567890.0 ~task_id:"t6" ~req ~result in
  assert (payload_member "fallback_reason" json = `String "llm timeout");
  assert (payload_member "gate" json = `String "fallback")
)

let () = Printf.printf "\n✅ All Tool_task tests passed!\n"
