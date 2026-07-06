module Types = Masc_domain

(** Coverage tests for Task.Tool *)

open Masc
module Planning_eio = Masc.Task.Planning_eio

let () = Random.self_init ()
let () = Mirage_crypto_rng_unix.use_default ()
let () = Keeper_task_owner_backend.install_hooks ()

let test_runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}
;;

let ensure_test_runtime =
  let initialized = Atomic.make false in
  let lock = Stdlib.Mutex.create () in
  let initialize_once () =
    let path = Filename.temp_file "tool_task_runtime_" ".toml" in
    let oc = open_out path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc test_runtime_toml);
    Fun.protect
      ~finally:(fun () ->
        try Sys.remove path with
        | Sys_error _ -> ())
      (fun () ->
         match Runtime.init_default ~config_path:path with
         | Ok () ->
             Atomic.set Workspace_hooks.get_default_runtime_id_fn
               Runtime.get_default_runtime_id;
             Atomic.set Task.Handlers.record_verdict_fn
               (fun ~task_id ~req ~result () ->
                  Eval_calibration.record_verdict ~task_id ~req ~result ());
             Atomic.set Task.Handlers.sse_broadcast_fn (fun _ -> ());
             Atomic.set Task.Handlers.push_event_to_sessions_fn (fun _ -> ());
             Atomic.set Task.Handlers.get_few_shot_block_fn (fun () ->
               Eval_calibration.format_few_shot_block
                 (Eval_calibration.select_examples ~max_examples:3));
             Atomic.set initialized true
         | Error msg -> failwith msg)
  in
  fun () ->
    if not (Atomic.get initialized)
    then (
      Stdlib.Mutex.lock lock;
      Fun.protect
        ~finally:(fun () -> Stdlib.Mutex.unlock lock)
        (fun () ->
           if not (Atomic.get initialized) then initialize_once ()))
;;

let install_test_hooks () =
  Atomic.set Workspace_hooks.get_default_runtime_id_fn Runtime.get_default_runtime_id;
  Atomic.set Task.Handlers.record_verdict_fn
    (fun ~task_id ~req ~result () ->
       Eval_calibration.record_verdict ~task_id ~req ~result ());
  Atomic.set Task.Handlers.get_few_shot_block_fn (fun () -> "")

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
      with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "false") (fun () ->
        with_env "MASC_CDAL_GATE_ENABLED" (Some "false") f)))

(* Test registry — collect via [test] then dispatch with Alcotest.run.
   Eio scope set up per-test inside the registered thunk. *)
let test_cases : (string * (unit -> unit)) list ref = ref []

let test name f =
  test_cases := (name, fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    ensure_test_runtime ();
    install_test_hooks ();
    with_isolated_runtime_env f) :: !test_cases

(* Create test context *)
let test_counter = ref 0
let make_test_ctx_with_agent agent_name =
  incr test_counter;
  let tmp = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-task-test-%d-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) !test_counter) in
  Unix.mkdir tmp 0o755;
  let config = Workspace.default_config tmp in
  let _ = Workspace.init config ~agent_name:(Some agent_name) in
  { Task.Tool.config; agent_name; sw = None }

let make_test_ctx () = make_test_ctx_with_agent "test-agent"

let corrupt_goal_store config =
  Fs_compat.save_file (Goal_store.goals_path config) "{not-json";
  Fs_compat.save_file (Goal_store.goals_path config ^ ".last-good") "{not-json"
;;

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

let json_member keys json =
  List.fold_left (fun acc key -> Yojson.Safe.Util.member key acc) json keys

let json_string path json =
  json_member path json |> Yojson.Safe.Util.to_string

let json_bool path json =
  json_member path json |> Yojson.Safe.Util.to_bool

let str_starts_with ~prefix s =
  let len_s = String.length s in
  let len_prefix = String.length prefix in
  len_s >= len_prefix && String.sub s 0 len_prefix = prefix

let make_task_contract ?(strict = false) ?(completion_contract = [])
    ?(required_evidence = []) ?(inspect_gate_evidence = [])
    ?(verify_gate_evidence = []) () : Masc_domain.task_contract =
  {
    strict;
    completion_contract;
    required_evidence;
    inspect_gate_evidence;
    verify_gate_evidence;
    evidence_claims = [];
    stale_claim_timeout_sec = 0;
    links = { operation_id = None; session_id = None };
  }

let add_priority_task ctx ~title =
  let result =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("title", `String title);
          ("priority", `Int 1);
        ])
  in
  if not (Tool_result.is_success result) then failwith (Tool_result.message result)

let start_task_001 ctx =
  let claim =
    Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("task_id", `String "task-001") ])
  in
  if not (Tool_result.is_success claim) then failwith (Tool_result.message claim);
  let start =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "start");
        ])
  in
  if not (Tool_result.is_success start) then failwith (Tool_result.message start)

let with_cdal_evidence_gate_decide decide f =
  let previous = Atomic.get Workspace_hooks.cdal_evidence_gate_decide_fn in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.cdal_evidence_gate_decide_fn previous)
    (fun () ->
       Atomic.set Workspace_hooks.cdal_evidence_gate_decide_fn decide;
       f ())

let workspace_evidence_verdict_of_cdal = function
  | Cdal_evidence_gate.Pass -> Workspace_hooks.Pass
  | Cdal_evidence_gate.Reject { reason; rule_id; hint; payload_json } ->
      Workspace_hooks.Reject { reason; rule_id; hint; payload_json }

let real_cdal_evidence_gate ~task_id ~task_opt ~notes ~handoff () =
  Cdal_evidence_gate.decide
    ~task_id
    ~task_opt
    ~notes
    ~handoff_context:handoff
    ()
  |> workspace_evidence_verdict_of_cdal

let verifier_transition_action_denylist =
  List.map
    (fun action -> "masc_transition:" ^ action)
    [
      "claim";
      "start";
      "done";
      "cancel";
      "release";
      "submit_for_verification";
    ]

let () =
  test "transition_action_denylist fails closed on meta read failure" (fun () ->
      let agent_name = "policy-read-error-agent" in
      let keeper_name =
        match Keeper_identity.canonical_keeper_name agent_name with
        | Some name -> name
        | None -> failwith "expected canonical keeper name for policy read error test"
      in
      let ctx = make_test_ctx_with_agent agent_name in
      let meta_path =
        Keeper_types_profile.keeper_meta_path ctx.Task.Tool.config keeper_name
      in
      let rec mkdir_p path =
        if path = "" || path = "." || path = "/" then ()
        else if Sys.file_exists path then ()
        else (
          mkdir_p (Filename.dirname path);
          Unix.mkdir path 0o755)
      in
      mkdir_p (Filename.dirname meta_path);
      let oc = open_out meta_path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc "{not-json");
      let denylist =
        Keeper_task_owner_backend.transition_action_denylist
          ctx.Task.Tool.config
          ~agent_name
      in
      let expected =
        Masc_domain.valid_task_action_strings
        |> List.map Task.Handlers.transition_action_denylist_entry
        |> List.sort String.compare
      in
      assert (List.sort String.compare denylist = expected))

let register_test_keeper ?(tool_denylist = []) ctx ~keeper_name ~agent_name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String keeper_name);
          ("agent_name", `String agent_name);
          ("trace_id", `String ("test-trace-" ^ keeper_name));
          ( "tool_denylist",
            `List (List.map (fun tool -> `String tool) tool_denylist) );
        ])
  with
  | Ok meta ->
      ignore
        (Keeper_registry.register_offline ~base_path:ctx.Task.Tool.config.Workspace.base_path
           keeper_name meta)
  | Error e -> failwith ("failed to build keeper meta: " ^ e)

let set_only_task_do_not_reclaim_reason ctx reason =
  let config = ctx.Task.Tool.config in
  let backlog = Workspace.read_backlog config in
  match backlog.Masc_domain.tasks with
  | [ task ] ->
      Workspace.write_backlog config
        { Masc_domain.tasks = [ { task with do_not_reclaim_reason = Some reason } ];
          last_updated = Masc_domain.now_iso ();
          version = backlog.version + 1;
        }
  | tasks ->
      failwith
        (Printf.sprintf "expected exactly one task, got %d" (List.length tasks))

let only_task ctx =
  match Workspace.get_tasks_raw ctx.Task.Tool.config with
  | [ task ] -> task
  | tasks ->
      failwith
        (Printf.sprintf "expected exactly one task, got %d" (List.length tasks))

let assert_task_todo ctx =
  match (only_task ctx).Masc_domain.task_status with
  | Masc_domain.Todo -> ()
  | _ -> failwith "expected task to remain todo"

let assert_task_claimed_by ctx agent_name =
  match (only_task ctx).Masc_domain.task_status with
  | Masc_domain.Claimed { assignee; _ } -> assert (assignee = agent_name)
  | _ -> failwith "expected task to be claimed"

let assert_task_awaiting_verification_by ctx agent_name =
  match (only_task ctx).Masc_domain.task_status with
  | Masc_domain.AwaitingVerification { assignee; verification_id; _ } ->
      assert (assignee = agent_name);
      assert (verification_id <> "")
  | _ -> failwith "expected task to be awaiting verification"

let set_only_task_contract ctx contract =
  let config = ctx.Task.Tool.config in
  let backlog = Workspace.read_backlog config in
  match backlog.Masc_domain.tasks with
  | [ task ] ->
      Workspace.write_backlog config
        {
          Masc_domain.tasks = [ { task with contract } ];
          last_updated = Masc_domain.now_iso ();
          version = backlog.version + 1;
        }
  | tasks ->
      failwith
        (Printf.sprintf "expected exactly one task, got %d" (List.length tasks))

(* Test dispatch returns None for unknown tool *)
let () = test "dispatch_unknown_tool" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  assert (Task.Tool.dispatch ctx ~name:"unknown_tool" ~args = None)
)

(* Test dispatch add_task *)
let () = test "dispatch_add_task" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("title", `String "Test task"); ("priority", `Int 2)] in
  match Task.Tool.dispatch ctx ~name:"masc_add_task" ~args with
  | Some result -> assert (Tool_result.is_success result)
  | None -> failwith "dispatch returned None"
)

let () = test "handle_add_task_returns_structured_task_id" (fun () ->
  let ctx = make_test_ctx () in
  let result =
    Task.Tool.handle_add_task ~tool_name:"masc_add_task" ~start_time:0.0 ctx
      (`Assoc
        [ ("title", `String "Structured task")
        ; ("priority", `Int 2)
        ; ("description", `String "structured add-task regression")
        ])
  in
  assert (Tool_result.is_success result);
  let data = Tool_result.data result in
  assert (Json_util.get_bool data "ok" = Some true);
  assert (Json_util.get_string data "task_id" = Some "task-001");
  assert (Json_util.get_string data "title" = Some "Structured task");
  assert (Json_util.assoc_member_opt "result" data = None);
  match Json_util.get_string data "summary" with
  | Some summary -> assert (str_contains summary "Added task-001")
  | None -> failwith "missing summary")

let () = test "handle_add_task_duplicate_returns_workflow_rejection" (fun () ->
  let ctx = make_test_ctx () in
  let first =
    Task.Tool.handle_add_task ~tool_name:"masc_add_task" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Duplicate contract task") ])
  in
  if not (Tool_result.is_success first) then failwith (Tool_result.message first);
  let duplicate =
    Task.Tool.handle_add_task ~tool_name:"masc_add_task" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Duplicate contract task") ])
  in
  assert (not (Tool_result.is_success duplicate));
  assert ((Tool_result.failure_class duplicate) = Some Tool_result.Workflow_rejection);
  assert (str_contains (Tool_result.message duplicate) "Duplicate rejected");
  assert (str_contains (Tool_result.message duplicate) "task-001"))

let () = test "workspace_add_task_with_result_returns_typed_task_id" (fun () ->
  let ctx = make_test_ctx () in
  match
    Workspace.add_task_with_result
      ctx.config
      ~title:"Structured task: title punctuation is display-only"
      ~priority:2
      ~description:"structured workspace add-task regression"
  with
  | Ok created ->
    assert (created.task_id = "task-001");
    assert (created.title = "Structured task: title punctuation is display-only");
    assert (created.priority = 2);
    assert (created.goal_id = None)
  | Error err ->
    failwith
      (Printf.sprintf
         "expected typed add_task success, got %s"
         (Workspace.add_task_error_to_string err)))

let () = test "handle_batch_add_tasks_returns_structured_task_ids" (fun () ->
  let ctx = make_test_ctx () in
  let result =
    Task.Tool.handle_batch_add_tasks ~tool_name:"masc_batch_add_tasks" ~start_time:0.0 ctx
      (`Assoc
        [
          ( "tasks",
            `List
              [
                `Assoc [ ("title", `String "Structured batch A") ];
                `Assoc [ ("title", `String "Structured batch B") ];
              ] );
        ])
  in
  assert (Tool_result.is_success result);
  let data = Tool_result.data result in
  assert (Json_util.get_bool data "ok" = Some true);
  assert (Json_util.get_int data "count" = Some 2);
  assert (Json_util.assoc_member_opt "result" data = None);
  (match Json_util.assoc_member_opt "task_ids" data with
   | Some (`List [ `String "task-001"; `String "task-002" ]) -> ()
   | _ -> failwith "missing structured batch task_ids");
  match Json_util.get_string data "summary" with
  | Some summary -> assert (str_contains summary "Added 2 tasks")
  | None -> failwith "missing summary")

(* Test dispatch tasks *)
let () = test "dispatch_tasks" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Task.Tool.dispatch ctx ~name:"masc_tasks" ~args with
  | Some result -> assert (Tool_result.is_success result)
  | None -> failwith "dispatch returned None"
)

let () = test "task_history_events_json_filters_by_task_id" (fun () ->
  let ctx = make_test_ctx () in
  let rec mkdir_p path =
    if path = "" || path = "." || path = "/" then ()
    else if Sys.file_exists path then ()
    else begin
      mkdir_p (Filename.dirname path);
      Unix.mkdir path 0o755
    end
  in
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  let month = Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  let events_dir = Filename.concat (Workspace.masc_dir ctx.config) "events" in
  let month_dir = Filename.concat events_dir month in
  let log_file = Filename.concat month_dir day in
  mkdir_p month_dir;
  let event task_id action =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("type", `String "task_transition");
          ("task_id", `String task_id);
          ("action", `String action);
          ("agent", `String ctx.agent_name);
          ("ts", `String "2026-04-18T00:00:00Z");
        ])
  in
  Fs_compat.append_file log_file (event "task-001" "claim" ^ "\n");
  Fs_compat.append_file log_file (event "task-002" "done" ^ "\n");
  let json = Task.Tool.task_history_events_json ctx.config ~task_id:"task-001" ~limit:20 in
  let events =
    match json with
    | `List rows -> rows
    | _ -> failwith "task history payload must be a JSON list"
  in
  assert (List.length events = 1);
  List.iter (fun row ->
    let open Yojson.Safe.Util in
    let task =
      match row |> member "task" with
      | `String value -> Some value
      | _ ->
          (match row |> member "task_id" with
           | `String value -> Some value
           | _ -> None)
    in
    assert (task = Some "task-001")
  ) events
)

let () = test "task_history_events_json_returns_empty_for_missing_task" (fun () ->
  let ctx = make_test_ctx () in
  let json = Task.Tool.task_history_events_json ctx.config ~task_id:"task-404" ~limit:20 in
  match json with
  | `List [] -> ()
  | `List _ -> failwith "missing task should have no history events"
  | _ -> failwith "task history payload must be a JSON list"
)
let () = test "masc_oas_bridge_fails_closed_without_eio_env" (fun () ->
  match Masc_eio_env.get_opt () with
  | Some _ ->
    failwith
      "masc_oas_bridge_fails_closed_without_eio_env requires Masc_eio_env.get_opt () = None before calling run_safe"
  | None ->
    let called = ref false in
    match
      Masc_oas_bridge.run_safe ~caller:"test_tool_task_coverage" ~timeout_s:0.1 (fun () ->
        called := true;
        Ok "ok")
    with
    | Error error ->
        if !called then failwith "run_safe called fn without an Eio env";
        (match Keeper_internal_error.classify_masc_internal_error error with
         | Some (Keeper_internal_error.Internal_bridge_exception { caller; _ }) ->
             if caller <> "test_tool_task_coverage" then
               failwith ("unexpected bridge caller: " ^ caller)
         | Some other ->
             failwith
               ( "unexpected internal error: "
               ^ Keeper_internal_error.kind_of_masc_internal_error other )
         | None ->
             failwith
               ("expected typed internal bridge error, got: "
               ^ Agent_sdk.Error.to_string error))
    | Ok other -> failwith ("unexpected success: " ^ other)
)

(* Test dispatch transition claim *)
let () = test "dispatch_transition_claim" (fun () ->
  let ctx = make_test_ctx () in
  (* First add a task *)
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Claim test")]) in
  let args = `Assoc [("task_id", `String "task-001"); ("action", `String "claim")] in
  match Task.Tool.dispatch ctx ~name:"masc_transition" ~args with
  | Some _ -> () (* May fail if task doesn't exist *)
  | None -> failwith "dispatch returned None"
)

(* Test dispatch claim_next *)
let () = test "dispatch_claim_next" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Task.Tool.dispatch ctx ~name:"keeper_task_claim" ~args with
  | Some _ -> ()
  | None -> failwith "dispatch returned None"
)

(* Test handle_done triggers calibration logging (#3164) *)
let () = test "handle_done_records_calibration_verdict" (fun () ->
  let ctx = make_test_ctx () in
  (* Setup: add task, claim it *)
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
    (`Assoc [("title", `String "Calibration test task")]) in
  let _ = Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx
    (`Assoc [("task_id", `String "task-001")]) in
  let verdict_dir = make_temp_dir "masc-verdict-test" in
  Eval_calibration.set_store_for_testing ~base_dir:verdict_dir;
  (* Trigger done with short notes (< 10 chars) to hit length gate *)
  let result = Task.Tool.handle_done ~tool_name:"test_tool" ~start_time:0.0 ctx
    (`Assoc [
      ("task_id", `String "task-001");
      ("notes", `String "x")
    ]) in
  assert (not (Tool_result.is_success result));
  assert (str_contains (Tool_result.message result) "Completion rejected by anti-rationalization gate");
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
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
    (`Assoc [("title", `String "Approved calibration task")]) in
  let _ = Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx
    (`Assoc [("task_id", `String "task-001")]) in
  let verdict_dir = make_temp_dir "masc-verdict-approve-test" in
  Eval_calibration.set_store_for_testing ~base_dir:verdict_dir;
  let result = Task.Tool.handle_done ~tool_name:"test_tool" ~start_time:0.0 ctx
    (`Assoc [
      ("task_id", `String "task-001");
      ("notes", `String "Task scope satisfied: Approved calibration task. Implemented the calibration coverage path, verified the JSONL verdict store, and completed the task cleanly. commit:abc123")
    ]) in
  if not (Tool_result.is_success result) then failwith (Tool_result.message result);
  let store = Eval_calibration.get_store () in
  let records = Dated_jsonl.read_recent store 10 in
  assert (List.length records >= 1);
  let first = List.hd records in
  let verdict = Yojson.Safe.Util.(first |> member "verdict" |> to_string) in
  assert (verdict = "approve");
  Eval_calibration.reset_store_for_testing ()
)

let () = test "handle_transition_respects_completion_contract_and_records_custom_evaluator" (fun () ->
  (* Legacy substring gate (Gate 2.5). When
     MASC_VERIFICATION_FSM_ENABLED=true, the persisted contract is passed to
     the LLM completion reviewer prompt. Pin the flag to [false] here to
     exercise the legacy local fallback this test asserts. *)
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "false") (fun () ->
    let ctx = make_test_ctx () in
    let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [("title", `String "Contract calibration task")]) in
    let _ = Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [("task_id", `String "task-001")]) in
    let verdict_dir = make_temp_dir "masc-verdict-contract-test" in
    Eval_calibration.set_store_for_testing ~base_dir:verdict_dir;
    let result = Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [
        ("task_id", `String "task-001");
        ("action", `String "done");
        ("notes", `String "Applied the fix to the login path.");
        ("completion_contract", `List [ `String "test coverage"; `String "migration" ]);
        ("evaluator_runtime", `String "glm:auto");
      ]) in
    assert (not (Tool_result.is_success result));
    assert (str_contains (Tool_result.message result) "completion contract not satisfied");
    let store = Eval_calibration.get_store () in
    let records = Dated_jsonl.read_recent store 10 in
    assert (List.length records >= 1);
    let first = List.hd records in
    let gate = Yojson.Safe.Util.(first |> member "gate" |> to_string) in
    let evaluator_runtime =
      Yojson.Safe.Util.(first |> member "evaluator_runtime" |> to_string)
    in
    assert (gate = "contract");
    assert (evaluator_runtime = "glm:auto");
    Eval_calibration.reset_store_for_testing ())
)

let () = test "handle_add_task_persists_contract" (fun () ->
  let ctx = make_test_ctx () in
  let result =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
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
  if not (Tool_result.is_success result) then failwith (Tool_result.message result);
  match Workspace.get_tasks_raw ctx.config with
  | [ task ] -> (
      match task.contract with
      | Some contract ->
          assert contract.strict;
          assert (contract.required_evidence = [ "run_deliverable" ])
      | None -> failwith "expected persisted task contract")
  | _ -> failwith "expected exactly one task"
)

let () = test "handle_add_task_injects_default_verification_contract" (fun () ->
  let ctx = make_test_ctx () in
  let result =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("title", `String "Default verification task");
          ("description", `String "Need verifier-visible evidence.");
        ])
  in
  if not (Tool_result.is_success result) then failwith (Tool_result.message result);
  match Workspace.get_tasks_raw ctx.config with
  | [ task ] -> (
      match task.contract with
      | Some contract ->
          assert (not contract.strict);
          assert (contract.completion_contract <> []);
          assert (List.mem "completion_notes" contract.required_evidence);
          assert (List.mem "reviewable_evidence_ref" contract.required_evidence);
          assert (List.mem "completion_notes" contract.verify_gate_evidence);
          assert (List.mem "reviewable_evidence_ref" contract.verify_gate_evidence);
          assert (str_contains (List.hd contract.completion_contract)
                    "Default verification task")
      | None -> failwith "expected default verification contract")
  | _ -> failwith "expected exactly one task"
)

let () = test "handle_batch_add_tasks_injects_default_verification_contracts" (fun () ->
  let ctx = make_test_ctx () in
  let result =
    Task.Tool.handle_batch_add_tasks ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ( "tasks",
            `List
              [
                `Assoc [ ("title", `String "Batch task A") ];
                `Assoc [ ("title", `String "Batch task B") ];
              ] );
        ])
  in
  if not (Tool_result.is_success result) then failwith (Tool_result.message result);
  let tasks = Workspace.get_tasks_raw ctx.config in
  assert (List.length tasks = 2);
  List.iter
    (fun (task : Masc_domain.task) ->
       match task.contract with
       | Some contract ->
           assert (contract.completion_contract <> []);
           assert (contract.verify_gate_evidence <> [])
       | None -> failwith "expected default verification contract for batch task")
    tasks
)

let () = test "handle_done_uses_llm_review_without_keeper_verifier_redirect" (fun () ->
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "true") (fun () ->
    with_env "MASC_CDAL_GATE_ENABLED" (Some "true") (fun () ->
      with_env "MASC_DATA_DIR" (Some (make_temp_dir "masc-cdal-empty")) (fun () ->
        let ctx = make_test_ctx () in
        let _ =
          Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
            (`Assoc
              [
                ("title", `String "Strict verifier task");
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
        let _ =
          Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx
            (`Assoc [ ("task_id", `String "task-001") ])
        in
        let result_done =
          Task.Tool.handle_done ~tool_name:"test_tool" ~start_time:0.0 ctx
            (`Assoc
              [
                ("task_id", `String "task-001");
                ( "notes",
                  `String
                    "Implemented deliverable-ready output and captured artifact:run_deliverable evidence." );
              ])
        in
        if not (Tool_result.is_success result_done) then
          failwith (Tool_result.message result_done);
        match (only_task ctx).Masc_domain.task_status with
        | Masc_domain.Done { assignee; _ } -> assert (String.equal assignee "test-agent")
        | other ->
          failwith
            (Printf.sprintf
               "expected Done after LLM review, got: %s"
               (Masc_domain.task_status_to_string other))))))

let () = test "handle_transition_release_requires_handoff_for_strict_task" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("title", `String "Strict release task");
          ("contract", `Assoc [ ("strict", `Bool true) ]);
        ])
  in
  let _ = Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ ("task_id", `String "task-001") ]) in
  let result_missing =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "release");
        ])
  in
  assert (not (Tool_result.is_success result_missing));
  assert (str_contains (Tool_result.message result_missing) "handoff_context.summary");
  let result_release =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
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
  if not (Tool_result.is_success result_release) then failwith (Tool_result.message result_release);
  match Workspace.get_tasks_raw ctx.config with
  | [ task ] -> (
      assert (task.do_not_reclaim_reason = None);
      match task.handoff_context with
      | Some handoff_context ->
          assert (handoff_context.summary = "blocked on integration fixture");
          assert (handoff_context.updated_by = Some "test-agent")
      | None -> failwith "expected persisted handoff_context")
  | _ -> failwith "expected exactly one task"
)

let () = test "handle_transition_start_on_todo_points_at_claim_first" (fun () ->
  (* Field evidence 2026-04-17/18: keepers attempted transitions on
     tasks they had not claimed. The FSM rejects [Start] on [Todo]
     because Start requires Claimed ownership, landing in the
     fallthrough branch. The enriched error must name masc_transition
     action=claim as the next concrete call. *)
  let ctx = make_test_ctx () in
  let before_seq =
    match Log.Ring.recent ~limit:1 () with
    | entry :: _ -> entry.Log.Ring.seq
    | [] -> -1
  in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Start-without-claim") ])
  in
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "start");
        ])
  in
  assert (not (Tool_result.is_success result));
  assert (str_contains (Tool_result.message result) "Invalid task state");
  assert (str_contains (Tool_result.message result) "todo");
  assert (str_contains (Tool_result.message result) "Valid actions");
  assert (str_contains (Tool_result.message result) "claim");
  (* The output must be a structured workflow rejection so the OAS retry
     ladder treats it as deterministic non-retryable. *)
  let rejection_json = Yojson.Safe.from_string (Tool_result.message result) in
  assert (json_string [ "failure_class" ] rejection_json = "workflow_rejection");
  assert (json_string [ "error_class" ] rejection_json = "deterministic");
  assert (not (json_bool [ "recoverable" ] rejection_json));
  let task_entries =
    Log.Ring.recent ~limit:50 ~module_filter:"Task" ~since_seq:before_seq ()
  in
  match
    List.find_opt
      (fun (entry : Log.Ring.entry) ->
         str_contains entry.message "task transition failed:"
         && str_contains entry.message
              "Transition 'start' from status 'todo'")
      task_entries
  with
  | Some entry ->
      assert (Log.level_to_string entry.level = "WARN")
  | None ->
      failwith "expected invalid transition to be logged through Task ring"
)

let () = test "handle_transition_release_by_nonowner_redirects_to_board_post"
    (fun () ->
  (* When a different agent claims the task, a release attempt by the
     non-owner must land in the fallthrough branch with ownership-mismatch
     and redirect to masc_board_post rather than reflexive retry. *)
  let ctx_owner = make_test_ctx_with_agent "owner-agent" in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx_owner
      (`Assoc [ ("title", `String "Owned-by-other") ])
  in
  let _ =
    Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx_owner
      (`Assoc [ ("task_id", `String "task-001") ])
  in
  (* A separate context for a different agent against the SAME config,
     so the backlog/task state is shared. *)
  let ctx_other =
    { ctx_owner with Task.Tool.agent_name = "other-agent" }
  in
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx_other
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "release");
        ])
  in
  assert (not (Tool_result.is_success result));
  assert ((Tool_result.failure_class result) = Some Tool_result.Workflow_rejection);
  assert (str_contains (Tool_result.message result) "Task task-001 is claimed");
  assert (str_contains (Tool_result.message result) "owner-agent");
  assert (str_contains (Tool_result.message result) "masc_board_post")
  ;
  let data = Tool_result.data result in
  assert (Json_util.get_string data "task_id" = Some "task-001");
  assert (Json_util.get_string data "current_assignee" = Some "owner-agent");
  assert (
    match Json_util.assoc_member_opt "diagnosis" data with
    | Some diagnosis ->
      Json_util.get_string diagnosis "rule_id"
      = Some "task_release_requires_current_owner"
      && Json_util.get_string diagnosis "tool_suggestion"
         = Some "keeper_board_post"
    | None -> false)
)

let () = test "handle_transition_force_release_by_admin_bypasses_nonowner_redirect"
    (fun () ->
  let ctx_owner = make_test_ctx_with_agent "owner-agent" in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx_owner
      (`Assoc [ ("title", `String "Force-release owned task") ])
  in
  let _ =
    Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx_owner
      (`Assoc [ ("task_id", `String "task-001") ])
  in
  let ctx_admin =
    { ctx_owner with Task.Tool.agent_name = "admin-agent" }
  in
  let previous_is_admin = Atomic.get Workspace_hooks.is_admin_agent_fn in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.is_admin_agent_fn previous_is_admin)
    (fun () ->
       Atomic.set Workspace_hooks.is_admin_agent_fn
         (fun ~base_path:_ ~agent_name ->
            String.equal agent_name "admin-agent");
       let result =
         Task.Tool.handle_transition
           ~tool_name:"test_tool"
           ~start_time:0.0
           ctx_admin
           (`Assoc
              [
                ("task_id", `String "task-001");
                ("action", `String "release");
                ("force", `Bool true);
              ])
       in
       assert (Tool_result.is_success result);
       match
         Workspace.get_tasks_raw ctx_owner.Task.Tool.config
         |> List.find_opt (fun (task : Masc_domain.task) ->
              String.equal task.id "task-001")
       with
       | Some { task_status = Masc_domain.Todo; _ } -> ()
       | Some task ->
         failwith
           (Printf.sprintf
              "expected forced release to return task-001 to todo, got %s"
              (Masc_domain.task_status_to_string task.task_status))
       | None -> failwith "missing task-001 after forced release")
)

let () = test "handle_transition_rejects_submit_when_verification_disabled"
    (fun () ->
  let ctx = make_test_ctx_with_agent "owner-agent" in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Verification disabled gate") ])
  in
  let _ =
    Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("task_id", `String "task-001") ])
  in
  let result =
    Task.Tool.handle_transition
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "submit_for_verification");
          ( "notes"
          , `String
              "completion_notes: implementation completed with verification \
               context. reviewable_evidence_ref: review evidence is attached."
          );
        ])
  in
  let message = Tool_result.message result in
  assert (not (Tool_result.is_success result));
  assert (str_contains message "Verification FSM not enabled");
  assert (not (str_contains message "Valid actions: start, done, submit_for_verification"))
)

let () = test "handle_transition_expected_version_mismatch_does_not_retry_without_cas"
    (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "CAS guarded task") ])
  in
  let result =
    Task.Tool.handle_transition
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc
         [
           ("task_id", `String "task-001");
           ("action", `String "claim");
           ("expected_version", `Int 999);
         ])
  in
  assert (not (Tool_result.is_success result));
  match Workspace.get_tasks_raw ctx.Task.Tool.config with
  | [ { Masc_domain.task_status = Masc_domain.Todo; _ } ] -> ()
  | [ task ] ->
    failwith
      (Printf.sprintf
         "expected stale expected_version to leave task todo, got %s"
         (Masc_domain.task_status_to_string task.task_status))
  | tasks ->
    failwith (Printf.sprintf "expected one task, got %d" (List.length tasks))
)

let () = test "handle_transition_release_synthesizes_summary_from_notes" (fun () ->
  (* Field evidence (2026-04-17/18): 76/132 masc_transition failures were
     empty/missing handoff_context.summary while the caller still supplied a
     non-empty top-level [notes] or [reason]. Auto-synthesize the summary from
     those siblings so the release transition succeeds instead of forcing the
     agent runtime to retry the exact same payload shape. *)
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("title", `String "Strict release with notes only");
          ("contract", `Assoc [ ("strict", `Bool true) ]);
        ])
  in
  let _ = Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ ("task_id", `String "task-001") ]) in
  let synthesized_note =
    "blocked on fixture reproduction; hand off to fixture-capable keeper"
  in
  let result_release =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "release");
          ("notes", `String synthesized_note);
          ("handoff_context", `Assoc []);
        ])
  in
  if not (Tool_result.is_success result_release) then failwith ("unexpected rejection: " ^ (Tool_result.message result_release));
  match Workspace.get_tasks_raw ctx.config with
  | [ task ] -> (
      match task.handoff_context with
      | Some handoff_context ->
          assert (handoff_context.summary = synthesized_note)
      | None -> failwith "expected persisted handoff_context")
  | _ -> failwith "expected exactly one task"
)

let () = test "handle_transition_release_prefers_notes_then_reason_for_synthesis" (fun () ->
  (* [notes] takes precedence over [reason] when synthesizing summary from
     sibling transition args. Both are single-line truncated, multi-line input
     collapses to the first line only. *)
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("title", `String "Strict release with both notes and reason");
          ("contract", `Assoc [ ("strict", `Bool true) ]);
        ])
  in
  let _ = Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ ("task_id", `String "task-001") ]) in
  let notes_line = "notes-line-should-win" in
  let result_release =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "release");
          ("notes", `String (notes_line ^ "\nsecond line dropped"));
          ("reason", `String "reason-line-should-lose");
          ("handoff_context", `Assoc []);
        ])
  in
  if not (Tool_result.is_success result_release) then failwith ("unexpected rejection: " ^ (Tool_result.message result_release));
  match Workspace.get_tasks_raw ctx.config with
  | [ task ] -> (
      match task.handoff_context with
      | Some handoff_context ->
          assert (handoff_context.summary = notes_line)
      | None -> failwith "expected persisted handoff_context")
  | _ -> failwith "expected exactly one task"
)

(* Regression: 2026-05-17 nick0cave production case. masc_transition with
   action=claim/start does not require [handoff_context.summary]; the LLM
   has nothing to summarize at work entry. Previously the parser rejected
   any empty summary regardless of action, which broke entry-class
   transitions when the keeper did not invent a placeholder. *)
let () = test "handle_transition_claim_does_not_require_summary" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Entry-class action") ])
  in
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "claim");
        ])
  in
  if not (Tool_result.is_success result) then
    failwith
      ("claim must succeed without handoff_context.summary: "
       ^ (Tool_result.message result))
)

let () = test "handle_transition_claim_with_empty_handoff_context_ok" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Entry with empty context") ])
  in
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "claim");
          (* Empty handoff_context object: keeper sent the shape but no
             content. Entry-class action treats this as absent, not as
             an error. *)
          ("handoff_context", `Assoc [ ("summary", `String "") ]);
        ])
  in
  if not (Tool_result.is_success result) then
    failwith
      ("claim with empty handoff_context.summary must succeed: "
       ^ (Tool_result.message result))
)

let () = test "handle_transition_done_still_requires_summary" (fun () ->
  (* Exit-class action [done] keeps the strict summary contract.
     Regression guard: the entry-class relaxation above must not leak
     into exit-class actions. *)
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("title", `String "Strict done task");
          ("contract", `Assoc [ ("strict", `Bool true) ]);
        ])
  in
  let _ =
    Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("task_id", `String "task-001") ])
  in
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "done");
          ("handoff_context", `Assoc [ ("summary", `String "") ]);
        ])
  in
  assert (not (Tool_result.is_success result));
  assert
    (str_contains (Tool_result.message result)
       "handoff_context.summary is required for action=done")
)

let () = test "handle_transition_release_empty_summary_error_includes_example" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("title", `String "Strict release task");
          ("contract", `Assoc [ ("strict", `Bool true) ]);
        ])
  in
  let _ = Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ ("task_id", `String "task-001") ]) in
  (* Empty-string summary must also fail, and error must include a payload example
     so the agent runtime can self-correct instead of retrying the same partial payload. *)
  let result_empty =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "release");
          ( "handoff_context",
            `Assoc
              [
                ("summary", `String "   ");
                ("next_step", `String "re-check fixture");
              ] );
        ])
  in
  assert (not (Tool_result.is_success result_empty));
  assert (str_contains (Tool_result.message result_empty) "handoff_context.summary is required");
  assert (str_contains (Tool_result.message result_empty) "Example");
  assert (str_contains (Tool_result.message result_empty) "\"summary\"")
)

let () = test "handle_transition_done_prefers_ownership_error_over_cdal_gate" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("title", `String "Strict owned task");
          ( "contract",
            `Assoc
              [
                ("strict", `Bool true);
                ("completion_contract", `List [ `String "deliverable-ready" ]);
              ] );
        ])
  in
  let _ = Workspace.claim_task ctx.config ~agent_name:"other-agent" ~task_id:"task-001" in
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "done");
          ("notes", `String "deliverable-ready");
        ])
  in
  assert (not (Tool_result.is_success result));
  assert (str_contains (Tool_result.message result) "currently owned by other-agent");
  assert (not (str_contains (Tool_result.message result) "contract verdict"))
)

let () = test "handle_transition_done_rejects_cdal_evidence_gate_failure" (fun () ->
  let ctx = make_test_ctx () in
  let add_result =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("title", `String "CDAL Done gate task");
          ( "contract",
            `Assoc
              [
                ("required_evidence", `List [ `String "artifact:run_deliverable" ]);
              ] );
        ])
  in
  if not (Tool_result.is_success add_result) then
    failwith (Tool_result.message add_result);
  set_only_task_contract ctx
    (Some
       (make_task_contract
          ~required_evidence:[ "artifact:run_deliverable" ]
          ()));
  start_task_001 ctx;
  let gate_calls = ref 0 in
  with_cdal_evidence_gate_decide
    (fun ~task_id ~task_opt ~notes ~handoff:_ () ->
       incr gate_calls;
       assert (String.equal task_id "task-001");
       assert (str_contains notes "artifact:run_deliverable");
       (match task_opt with
        | Some { Masc_domain.contract = Some _; _ } -> ()
        | _ -> failwith "expected contracted task to reach CDAL gate");
       Workspace_hooks.Reject
         {
           reason = "missing reviewable evidence";
           rule_id = "cdal_evidence_incomplete";
           hint = "Attach concrete evidence before marking the task done.";
           payload_json = `Assoc [ ("source", `String "test") ];
         })
    (fun () ->
       let result =
         Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
           (`Assoc
             [
               ("task_id", `String "task-001");
               ("action", `String "done");
               ( "notes",
                 `String
                   "Implemented deliverable-ready output with artifact:run_deliverable evidence." );
             ])
       in
       assert (!gate_calls = 1);
       assert (not (Tool_result.is_success result));
       assert ((Tool_result.failure_class result) = Some Tool_result.Workflow_rejection);
       let payload = Yojson.Safe.from_string (Tool_result.message result) in
       assert
         (json_string [ "diagnosis"; "rule_id" ] payload
          = "cdal_evidence_incomplete"))
)

let () = test "handle_transition_done_no_contract_passes_real_cdal_gate" (fun () ->
  let ctx = make_test_ctx () in
  let add_message =
    Workspace.add_task
      ctx.config
      ~title:"Analysis-only Done task"
      ~priority:1
      ~description:"No persisted verification contract"
  in
  assert (str_starts_with ~prefix:"Added task-001" add_message);
  set_only_task_contract ctx None;
  start_task_001 ctx;
  let gate_calls = ref 0 in
  with_cdal_evidence_gate_decide
    (fun ~task_id ~task_opt ~notes ~handoff () ->
       incr gate_calls;
       assert (String.equal task_id "task-001");
       assert (str_contains notes "commit:abc123");
       (match task_opt with
        | Some { Masc_domain.contract = None; _ } -> ()
        | _ -> failwith "expected analysis-only task with no contract");
       real_cdal_evidence_gate ~task_id ~task_opt ~notes ~handoff ())
    (fun () ->
       let result =
         Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
           (`Assoc
             [
               ("task_id", `String "task-001");
               ("action", `String "done");
               ( "notes",
                 `String
                   "Analysis-only task completed with implementation notes and commit:abc123." );
             ])
       in
       assert (!gate_calls = 1);
       if not (Tool_result.is_success result) then
         failwith (Tool_result.message result);
       match (only_task ctx).Masc_domain.task_status with
       | Masc_domain.Done { assignee; _ } -> assert (String.equal assignee "test-agent")
       | other ->
         failwith
           (Printf.sprintf
              "expected Done after no-contract CDAL pass, got: %s"
              (Masc_domain.task_status_to_string other)))
)

let () = test "handle_transition_done_default_contract_accepts_default_evidence_tokens" (fun () ->
  let ctx = make_test_ctx () in
  let add_result =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("title", `String "Default contract Done task");
          ("description", `String "Mirrors contract harness task completion.");
        ])
  in
  if not (Tool_result.is_success add_result) then
    failwith (Tool_result.message add_result);
  start_task_001 ctx;
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "done");
          ( "notes",
            `String
              "completion_notes: contract harness completed the live workflow. \
               Task scope satisfied: Default contract Done task - Mirrors \
               contract harness task completion. \
               reviewable_evidence_ref: contract-harness transcript." );
        ])
  in
  if not (Tool_result.is_success result) then
    failwith (Tool_result.message result);
  match (only_task ctx).Masc_domain.task_status with
  | Masc_domain.Done { assignee; _ } -> assert (String.equal assignee "test-agent")
  | other ->
    failwith
      (Printf.sprintf
         "expected Done after default-contract CDAL pass, got: %s"
         (Masc_domain.task_status_to_string other))
)

let () = test "handle_transition_force_done_still_rejects_cdal_evidence_incomplete" (fun () ->
  let ctx = make_test_ctx_with_agent "admin-agent" in
  let add_result =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("title", `String "Forced Done evidence task");
          ( "contract",
            `Assoc
              [
                ("required_evidence", `List [ `String "artifact:run_deliverable" ]);
              ] );
        ])
  in
  if not (Tool_result.is_success add_result) then
    failwith (Tool_result.message add_result);
  set_only_task_contract ctx
    (Some
       (make_task_contract
          ~required_evidence:[ "artifact:run_deliverable" ]
          ()));
  start_task_001 ctx;
  let previous_is_admin = Atomic.get Workspace_hooks.is_admin_agent_fn in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.is_admin_agent_fn previous_is_admin)
    (fun () ->
       Atomic.set Workspace_hooks.is_admin_agent_fn
         (fun ~base_path:_ ~agent_name ->
            String.equal agent_name "admin-agent");
       let gate_calls = ref 0 in
       with_cdal_evidence_gate_decide
         (fun ~task_id ~task_opt ~notes ~handoff () ->
            incr gate_calls;
            real_cdal_evidence_gate ~task_id ~task_opt ~notes ~handoff ())
         (fun () ->
            let result =
              Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
                (`Assoc
                  [
                    ("task_id", `String "task-001");
                    ("action", `String "done");
                    ("force", `Bool true);
                    ("notes", `String "");
                  ])
            in
            assert (!gate_calls = 1);
            assert (not (Tool_result.is_success result));
            assert
              ((Tool_result.failure_class result)
               = Some Tool_result.Workflow_rejection);
            let payload = Yojson.Safe.from_string (Tool_result.message result) in
            assert
              (json_string [ "diagnosis"; "rule_id" ] payload
               = "cdal_evidence_incomplete");
            match (only_task ctx).Masc_domain.task_status with
            | Masc_domain.InProgress { assignee; _ } ->
              assert (String.equal assignee "admin-agent")
            | other ->
              failwith
                (Printf.sprintf
                   "evidence-gated force=true Done must not mutate status, got: %s"
                   (Masc_domain.task_status_to_string other))))
)

let () = test "handle_transition_done_on_awaiting_verification_is_explicit" (fun () ->
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "true") (fun () ->
    let ctx = make_test_ctx () in
    let _ =
      Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc
          [
            ("title", `String "Awaiting verification task");
            ( "contract",
              `Assoc
                [
                  ("strict", `Bool true);
                  ("completion_contract", `List [ `String "tests pass" ]);
                ] );
          ])
    in
    let _ = Workspace.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001" in
    let _ =
      Workspace.transition_task_r ctx.config ~agent_name:"test-agent"
        ~task_id:"task-001" ~action:Masc_domain.Submit_for_verification ()
    in
    let result =
      Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "done");
            ("notes", `String "tests pass");
          ])
    in
    assert (not (Tool_result.is_success result));
    assert (str_contains (Tool_result.message result) "awaiting verification");
    assert (str_contains (Tool_result.message result) "approve or reject")))

let () = test "handle_transition_verifier_blocks_non_verdict_actions" (fun () ->
  let ctx = make_test_ctx_with_agent "verifier" in
  register_test_keeper ctx ~keeper_name:"verifier" ~agent_name:"verifier"
    ~tool_denylist:verifier_transition_action_denylist;
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Verifier must not claim") ])
  in
  List.iter
    (fun action ->
      let result =
        Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
          (`Assoc
            [
              ("task_id", `String "task-001");
              ("action", `String action);
              ("notes", `String "stale verifier context attempted workflow mutation");
            ])
      in
      assert (not (Tool_result.is_success result));
      assert
        ((Tool_result.failure_class result) = Some Tool_result.Workflow_rejection);
      assert (str_contains (Tool_result.message result) "Transition action policy guard");
      assert (str_contains (Tool_result.message result) "approve|reject"))
    [ "claim"; "done"; "submit_for_verification" ];
  assert_task_todo ctx;
  assert (Planning_eio.get_current_task ctx.config = None))

let () = test "handle_transition_verifier_noops_terminal_verdicts" (fun () ->
  let ctx = make_test_ctx_with_agent "worker" in
  register_test_keeper ctx ~keeper_name:"verifier" ~agent_name:"verifier"
    ~tool_denylist:verifier_transition_action_denylist;
  let verifier_ctx = { ctx with Task.Tool.agent_name = "verifier" } in
  let _ = Workspace.add_task ctx.config ~title:"Already done" ~priority:1 ~description:"" in
  let _ = Workspace.claim_task ctx.config ~agent_name:"worker" ~task_id:"task-001" in
  let done_result =
    Workspace.transition_task_r ctx.config ~agent_name:"worker"
      ~task_id:"task-001" ~action:Masc_domain.Done_action ~notes:"complete" ()
  in
  (match done_result with
   | Ok _ -> ()
   | Error err -> failwith (Masc_domain.masc_error_to_string err));
  List.iter
    (fun action ->
      let result =
        Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0
          verifier_ctx
          (`Assoc
            [
              ("task_id", `String "task-001");
              ("action", `String action);
              ("notes", `String "stale verifier verdict");
            ])
      in
      if not (Tool_result.is_success result) then failwith (Tool_result.message result);
      assert (str_contains (Tool_result.message result) "Stale verification verdict ignored");
      assert (str_contains (Tool_result.message result) "no-op"))
    [ "approve"; "reject" ];
  match (only_task ctx).Masc_domain.task_status with
  | Masc_domain.Done _ -> ()
  | _ -> failwith "expected terminal task to stay done")

let () = test "handle_transition_verifier_allows_verdict_actions" (fun () ->
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "true") (fun () ->
    let worker_ctx = make_test_ctx_with_agent "worker" in
    let verifier_ctx = { worker_ctx with Task.Tool.agent_name = "verifier" } in
    let _ =
      Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 worker_ctx
        (`Assoc [ ("title", `String "Verifier may approve") ])
    in
    let _ =
      Workspace.claim_task worker_ctx.config ~agent_name:"worker" ~task_id:"task-001"
    in
    let submit_result =
      Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0
        worker_ctx
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "submit_for_verification");
            ("notes", `String "completion_notes: verifier evidence prepared. reviewable_evidence_ref: artifact:verifier-evidence.json ready for verifier");
          ])
    in
    if not (Tool_result.is_success submit_result) then
      failwith (Tool_result.message submit_result);
    let result =
      Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0
        verifier_ctx
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "approve");
            ("notes", `String "evidence verified");
          ])
    in
    if not (Tool_result.is_success result) then failwith (Tool_result.message result);
    match (only_task worker_ctx).Masc_domain.task_status with
    | Masc_domain.Done _ -> ()
    | _ -> failwith "expected verifier approval to complete task"))

let () = test "handle_transition_blocks_submitter_verdict_actions" (fun () ->
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "true") (fun () ->
    let worker_ctx = make_test_ctx_with_agent "worker" in
    let _ =
      Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 worker_ctx
        (`Assoc [ ("title", `String "Submitter must not self-verify") ])
    in
    let _ =
      Workspace.claim_task worker_ctx.config ~agent_name:"worker" ~task_id:"task-001"
    in
    let submit_result =
      Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0
        worker_ctx
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "submit_for_verification");
            ( "notes",
              `String
                "completion_notes: self-verification regression setup. \
                 reviewable_evidence_ref: artifact:self-verification.json" );
          ])
    in
    if not (Tool_result.is_success submit_result) then
      failwith (Tool_result.message submit_result);
    List.iter
      (fun (action, expected) ->
         let result =
           Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0
             worker_ctx
             (`Assoc
               [
                 ("task_id", `String "task-001");
                 ("action", `String action);
                 ("notes", `String "rubber-stamp verdict");
               ])
         in
         assert (not (Tool_result.is_success result));
         assert ((Tool_result.failure_class result) = Some Tool_result.Workflow_rejection);
         assert (str_contains (Tool_result.message result) expected))
      [ "approve", "Self-approval not allowed"
      ; "reject", "Self-rejection not allowed"
      ];
    assert_task_awaiting_verification_by worker_ctx "worker"))

let () = test "handle_claim_sets_planning_current_task" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Claim direct")]) in
  let result =
    Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("task_id", `String "task-001")])
  in
  assert (Tool_result.is_success result);
  assert (Planning_eio.get_current_task ctx.config = Some "task-001")
)

let () = test "keeper_claim_does_not_clobber_planning_current_task" (fun () ->
  let ctx = make_test_ctx_with_agent "codex-mcp-client" in
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ ("title", `String "Operator task") ])
  in
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ ("title", `String "Keeper task") ])
  in
  (match Planning_eio.set_current_task ctx.config ~task_id:"task-001" with
   | Ok () -> ()
   | Error msg -> failwith ("failed to seed current_task: " ^ msg));
  ignore
    (Workspace.bind_session ctx.config ~agent_name:"keeper-executor-agent"
       ~capabilities:[] ());
  register_test_keeper ctx ~keeper_name:"executor"
    ~agent_name:"keeper-executor-agent";
  let keeper_ctx =
    { ctx with Task.Tool.agent_name = "keeper-executor-agent" }
  in
  let result =
    Task.Tool.handle_claim
      ~tool_name:"test_tool"
      ~start_time:0.0
      keeper_ctx
      (`Assoc [ ("task_id", `String "task-002") ])
  in
  assert (Tool_result.is_success result);
  assert (Planning_eio.get_current_task ctx.config = Some "task-001"))

let () = test "keeper_alias_claim_does_not_clobber_planning_current_task" (fun () ->
  let ctx = make_test_ctx_with_agent "codex-mcp-client" in
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ ("title", `String "Operator task") ])
  in
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ ("title", `String "Keeper task") ])
  in
  (match Planning_eio.set_current_task ctx.config ~task_id:"task-001" with
   | Ok () -> ()
   | Error msg -> failwith ("failed to seed current_task: " ^ msg));
  ignore
    (Workspace.bind_session ctx.config ~agent_name:"keeper-executor-agent"
       ~capabilities:[] ());
  register_test_keeper ctx ~keeper_name:"executor"
    ~agent_name:"keeper-executor-agent";
  let keeper_ctx =
    { ctx with Task.Tool.agent_name = "keeper-executor" }
  in
  let result =
    Task.Tool.handle_claim
      ~tool_name:"test_tool"
      ~start_time:0.0
      keeper_ctx
      (`Assoc [ ("task_id", `String "task-002") ])
  in
  assert (Tool_result.is_success result);
  assert (Planning_eio.get_current_task ctx.config = Some "task-001"))

let () = test "keeper_generated_alias_claim_does_not_clobber_planning_current_task" (fun () ->
  let ctx = make_test_ctx_with_agent "codex-mcp-client" in
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ ("title", `String "Operator task") ])
  in
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ ("title", `String "Keeper task") ])
  in
  (match Planning_eio.set_current_task ctx.config ~task_id:"task-001" with
   | Ok () -> ()
   | Error msg -> failwith ("failed to seed current_task: " ^ msg));
  ignore
    (Workspace.bind_session ctx.config ~agent_name:"keeper-executor-agent"
       ~capabilities:[] ());
  ignore
    (Workspace.bind_session ctx.config ~agent_name:"keeper-executor-warm-raven-agent"
       ~capabilities:[] ());
  register_test_keeper ctx ~keeper_name:"executor"
    ~agent_name:"keeper-executor-agent";
  let keeper_ctx =
    { ctx with Task.Tool.agent_name = "keeper-executor-warm-raven-agent" }
  in
  let result =
    Task.Tool.handle_claim
      ~tool_name:"test_tool"
      ~start_time:0.0
      keeper_ctx
      (`Assoc [ ("task_id", `String "task-002") ])
  in
  assert (Tool_result.is_success result);
  assert (Planning_eio.get_current_task ctx.config = Some "task-001"))

let () = test "keeper_separator_alias_claim_does_not_clobber_planning_current_task" (fun () ->
  let ctx = make_test_ctx_with_agent "codex-mcp-client" in
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ ("title", `String "Operator task") ])
  in
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ ("title", `String "Keeper task") ])
  in
  (match Planning_eio.set_current_task ctx.config ~task_id:"task-001" with
   | Ok () -> ()
   | Error msg -> failwith ("failed to seed current_task: " ^ msg));
  ignore
    (Workspace.bind_session ctx.config ~agent_name:"keeper-tech-glutton-agent"
       ~capabilities:[] ());
  ignore
    (Workspace.bind_session ctx.config ~agent_name:"keeper-tech_glutton-agent"
       ~capabilities:[] ());
  register_test_keeper ctx ~keeper_name:"tech-glutton"
    ~agent_name:"keeper-tech-glutton-agent";
  let keeper_ctx =
    { ctx with Task.Tool.agent_name = "keeper-tech_glutton-agent" }
  in
  let result =
    Task.Tool.handle_claim
      ~tool_name:"test_tool"
      ~start_time:0.0
      keeper_ctx
      (`Assoc [ ("task_id", `String "task-002") ])
  in
  assert (Tool_result.is_success result);
  assert (Planning_eio.get_current_task ctx.config = Some "task-001"))

let () = test "keeper_shaped_non_keeper_claim_updates_planning_current_task" (fun () ->
  let ctx = make_test_ctx_with_agent "codex-mcp-client" in
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ ("title", `String "Operator task") ])
  in
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ ("title", `String "Spoofed keeper task") ])
  in
  (match Planning_eio.set_current_task ctx.config ~task_id:"task-001" with
   | Ok () -> ()
   | Error msg -> failwith ("failed to seed current_task: " ^ msg));
  ignore
    (Workspace.bind_session ctx.config ~agent_name:"keeper-spoof-agent"
       ~capabilities:[] ());
  let spoof_ctx =
    { ctx with Task.Tool.agent_name = "keeper-spoof-agent" }
  in
  let result =
    Task.Tool.handle_claim
      ~tool_name:"test_tool"
      ~start_time:0.0
      spoof_ctx
      (`Assoc [ ("task_id", `String "task-002") ])
  in
  assert (Tool_result.is_success result);
  assert (Planning_eio.get_current_task ctx.config = Some "task-002"))

let () = test "handle_claim_rejects_when_agent_already_has_active_task" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ ("title", `String "First active task") ])
  in
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ ("title", `String "Second active task") ])
  in
  let first =
    Task.Tool.handle_claim
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ ("task_id", `String "task-001") ])
  in
  if not (Tool_result.is_success first) then failwith (Tool_result.message first);
  let second =
    Task.Tool.handle_claim
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ ("task_id", `String "task-002") ])
  in
  assert (not (Tool_result.is_success second));
  assert (str_contains (Tool_result.message second) "task(s) in progress: task-001");
  let task_001 =
    Workspace.get_tasks_raw ctx.config
    |> List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id "task-001")
  in
  let task_002 =
    Workspace.get_tasks_raw ctx.config
    |> List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id "task-002")
  in
  (match task_001 with
  | Some { task_status = Masc_domain.Claimed { assignee; _ }; _ } ->
    assert (String.equal assignee "test-agent")
  | Some _ -> failwith "task-001 should remain claimed"
  | None -> failwith "task-001 missing");
  match task_002 with
  | Some { task_status = Masc_domain.Todo; _ } -> ()
  | Some _ -> failwith "task-002 should remain todo"
  | None -> failwith "task-002 missing"
)

let () = test "handle_claim_rejects_removed_agent_role_argument" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ ("title", `String "Claim role arg") ])
  in
  let result =
    Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("agent_role", `String "worker");
        ])
  in
  assert (not (Tool_result.is_success result));
  assert (str_contains (Tool_result.message result) "agent_role is no longer supported")
)

let () = test "handle_claim_next_sets_planning_current_task" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Claim next")]) in
  let result = Task.Tool.handle_claim_next ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc []) in
  assert (Tool_result.is_success result);
  assert (Planning_eio.get_current_task ctx.config = Some "task-001")
)

let () = test "handle_claim_next_returns_claim_observation" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ ("title", `String "Claim observed") ])
  in
  let claim_result = Task.Tool.handle_claim_next ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc []) in
  if not (Tool_result.is_success claim_result) then failwith (Tool_result.message claim_result);
  let prefix = "claim_observation=" in
  let line =
    match
      List.find_opt
        (fun line -> str_starts_with ~prefix line)
        (String.split_on_char '\n' (Tool_result.message claim_result))
    with
    | Some line -> line
    | None -> failwith ("missing claim observation in result: " ^ (Tool_result.message claim_result))
  in
  let payload =
    String.sub line (String.length prefix) (String.length line - String.length prefix)
    |> Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  assert (payload |> member "event_type" |> to_string
          = "collaboration.todo.claim_observed");
  assert (payload |> member "substrate" |> member "kind" |> to_string = "todo_claim");
  assert (payload |> member "todo_claim" |> member "todo_id" |> to_string = "task-001");
  assert (payload |> member "todo_claim" |> member "state" |> to_string
          = "claim_verified");
  assert (payload |> member "todo_claim" |> member "winner_actor_id" |> to_string
          = ctx.agent_name)
)

(* scope_widened is threaded from Claim_next_claimed through
   build_claim_observation_payload into the todo_claim fragment. Assert both
   boolean values so a regression that drops the field (or hardcodes it) is
   caught. *)
let () = test "claim_observation_payload_carries_scope_widened" (fun () ->
  let open Yojson.Safe.Util in
  let scope_widened_of b =
    Task.Tool.build_claim_observation_payload ~now:0.0 ~agent_name:"agent-x"
      ~task_id:"task-001" ~scope_widened:b
    |> member "todo_claim" |> member "scope_widened" |> to_bool
  in
  assert (scope_widened_of true = true);
  assert (scope_widened_of false = false)
)

let () =
  test "handle_claim_next_reports_internal_errors_as_tool_failure" (fun () ->
    let ctx = make_test_ctx () in
    let add_result =
      Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc [ ("title", `String "Claim next internal error") ])
    in
    if not (Tool_result.is_success add_result) then failwith (Tool_result.message add_result);
    let corrupt path =
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc "{not valid json")
    in
    let backlog_path = Workspace.backlog_path ctx.config in
    corrupt backlog_path;
    corrupt (backlog_path ^ ".last-good");
    let result =
      Task.Tool.handle_claim_next
        ~tool_name:"test_tool"
        ~start_time:0.0
        ctx
        (`Assoc [])
    in
    assert (not (Tool_result.is_success result));
    assert (str_contains (Tool_result.message result) "Error:"))

let () = test "handle_claim_next_ignores_keeper_tool_access_for_open_claims" (fun () ->
  let agent_name = "keeper-social-sync-agent" in
  let keeper_name = "social-sync" in
  let ctx = make_test_ctx_with_agent agent_name in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String agent_name);
            ("trace_id", `String "trace-social-sync");
            ("tool_access", `List [ `String "masc_status" ]);
          ])
    with
    | Ok meta -> meta
    | Error e -> failwith ("meta_of_json failed: " ^ e)
  in
  (match Keeper_meta_store.write_meta ctx.config initial_meta with
  | Ok () -> ()
  | Error e -> failwith ("write_meta failed: " ^ e));
  (* Workspace.update_agent_r setup removed (2026-06-09): the agent-status
     registry it wrote was dead; claim eligibility uses keeper_meta above. *)
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Open claim task") ])
  in
  let result = Task.Tool.handle_claim_next ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc []) in
  assert (Tool_result.is_success result);
  match Workspace.get_tasks_raw ctx.config with
  | [ task ] -> (
      match task.task_status with
      | Masc_domain.Claimed { assignee; _ } -> assert (assignee = agent_name)
      | _ -> failwith ("expected task to be claimed: " ^ (Tool_result.message result)))
  | _ -> failwith ("expected exactly one task: " ^ (Tool_result.message result))
)

let () = test "transition_claim_sets_planning_current_task" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Transition claim")]) in
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [("task_id", `String "task-001"); ("action", `String "claim")])
  in
  assert (Tool_result.is_success result);
  assert (Planning_eio.get_current_task ctx.config = Some "task-001")
)

let () = test "transition_missing_task_clears_stale_current_task" (fun () ->
  let ctx = make_test_ctx () in
  (match Planning_eio.set_current_task ctx.config ~task_id:"task-1468" with
   | Ok () -> ()
   | Error msg -> failwith msg);
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [("task_id", `String "task-1468"); ("action", `String "start")])
  in
  assert (not (Tool_result.is_success result));
  assert (Tool_result.failure_class result = Some Tool_result.Workflow_rejection);
  assert (Planning_eio.get_current_task ctx.config = None);
  let data = Tool_result.data result in
  assert (Json_util.get_bool data "stale_context" = Some true);
  assert (
    match Json_util.assoc_member_opt "diagnosis" data with
    | Some diagnosis ->
      Json_util.get_string diagnosis "rule_id" = Some "stale_task_id_not_found"
      && Json_util.get_string diagnosis "tool_suggestion"
         = Some "keeper_tasks_list"
    | None -> false);
  assert (str_contains (Tool_result.message result) "absent from the live backlog")
)

(* RFC-0109 Phase E (#18822, 2026-05-27) retired the transition-layer
   substring evidence gate. The two tests that previously locked in
   the substring-reject behaviour
   ([transition_submit_for_verification_requires_evidence_ref] and
   [transition_submit_for_verification_rejects_placeholder_evidence_ref])
   have been removed: their intent was the exact behaviour Phase E
   removes.  Phase E semantics is now pinned by
   [test/test_task_state_verification_phase_e.ml] (5 cases) and by
   the typed contract verdict consultation in
   [test/test_cdal_evidence_gate.ml] (10 cases).  See issue #18830
   Cluster A.1 for the triage record. *)

let task_submit_evidence_notes =
  "completion_notes: implementation completed with verification context. \
   reviewable_evidence_ref: review evidence is attached."

let () = test "transition_submit_for_verification_todo_rejects_instead_of_alias" (fun () ->
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "true") (fun () ->
    let ctx = make_test_ctx_with_agent "codex-mcp-client" in
    add_priority_task ctx ~title:"No action alias";
    let result =
      Task.Tool.handle_transition
        ~tool_name:"test_tool" ~start_time:0.0
        ctx
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "submit_for_verification");
            ("notes", `String task_submit_evidence_notes);
          ])
    in
    assert (not (Tool_result.is_success result));
    assert (str_contains (Tool_result.message result) "Transition 'submit_for_verification'");
    assert (str_contains (Tool_result.message result) "from status 'todo' is not allowed");
    assert_task_todo ctx)
)

let () = test "transition_submit_pr_evidence_is_retired" (fun () ->
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "true") (fun () ->
    let ctx = make_test_ctx_with_agent "codex-mcp-client" in
    add_priority_task ctx ~title:"CLI approval follow-up";
    let result =
      Task.Tool.handle_transition
        ~tool_name:"test_tool" ~start_time:0.0
        ctx
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "submit_pr_evidence");
            ("notes", `String task_submit_evidence_notes);
          ])
    in
    assert (not (Tool_result.is_success result));
    assert (str_contains (Tool_result.message result) "Unknown task action: submit_pr_evidence");
    assert_task_todo ctx)
)

let () = test "transition_pr_url_top_level_is_retired" (fun () ->
  let ctx = make_test_ctx_with_agent "codex-mcp-client" in
  add_priority_task ctx ~title:"No transport pr_url alias";
  let result =
    Task.Tool.handle_transition
      ~tool_name:"test_tool" ~start_time:0.0
      ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "claim");
          ("pr_url", `String "https://github.com/jeong-sik/masc/pull/13169");
        ])
  in
  assert (not (Tool_result.is_success result));
  assert (str_contains (Tool_result.message result) "Unknown argument(s): pr_url");
  assert_task_todo ctx
)

(* RFC-0109 Phase E (#18822): the transition-layer substring gate that
   produced the "requires verification evidence" message no longer
   exists; this test's [str_contains "requires verification evidence"]
   assertion was the third lock-in of the retired behaviour and has
   been removed.  The remaining intent — contracted-task submit
   rejection when no contract verdict and no substantive evidence — is
   covered by [test/test_cdal_evidence_gate.ml]'s missing-verdict
   arm. See issue #18830 Cluster A.1. *)

let () = test "transition_claim_clears_legacy_cycle_do_not_reclaim_reason" (fun () ->
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "true") (fun () ->
    let ctx = make_test_ctx_with_agent "codex-mcp-client" in
    let result =
      Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc
          [
            ("title", `String "Strict accessor PR evidence");
            ("priority", `Int 1);
          ])
    in
    if not (Tool_result.is_success result) then failwith (Tool_result.message result);
    set_only_task_do_not_reclaim_reason ctx "auto: 3 releases";
    let claim_result =
      Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "claim");
          ])
    in
    if not (Tool_result.is_success claim_result) then failwith (Tool_result.message claim_result);
    assert_task_claimed_by ctx "codex-mcp-client";
    assert (Planning_eio.get_current_task ctx.config = Some "task-001"))
)

let () = test "transition_release_free_text_not_found_stays_reclaimable" (fun () ->
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "true") (fun () ->
    let ctx = make_test_ctx_with_agent "codex-mcp-client" in
    let result =
      Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc
          [
            ("title", `String "Missing worktree recovery");
            ("priority", `Int 1);
          ])
    in
    if not (Tool_result.is_success result) then failwith (Tool_result.message result);
    let claim_result =
      Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "claim");
          ])
    in
    if not (Tool_result.is_success claim_result) then failwith (Tool_result.message claim_result);
    let release_result =
      Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "release");
            ( "handoff_context",
              `Assoc
                [
                  ( "summary",
                    `String
                      "worktree path not found, spinning on path resolution for \
                       multiple turns, releasing to unblock" );
                ] );
          ])
    in
    if not (Tool_result.is_success release_result) then failwith (Tool_result.message release_result);
    assert_task_todo ctx;
    assert ((only_task ctx).do_not_reclaim_reason = None);
    let reclaim_result =
      Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "claim");
          ])
    in
    if not (Tool_result.is_success reclaim_result) then failwith (Tool_result.message reclaim_result);
    assert_task_claimed_by ctx "codex-mcp-client";
    assert (Planning_eio.get_current_task ctx.config = Some "task-001"))
)

let () = test "transition_release_block_reclaim_policy_closes_gate" (fun () ->
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "true") (fun () ->
    let ctx = make_test_ctx_with_agent "codex-mcp-client" in
    let result =
      Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc
          [
            ("title", `String "Terminal mismatch");
            ("priority", `Int 1);
          ])
    in
    if not (Tool_result.is_success result) then failwith (Tool_result.message result);
    let claim_result =
      Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "claim");
          ])
    in
    if not (Tool_result.is_success claim_result) then failwith (Tool_result.message claim_result);
    let release_result =
      Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "release");
            ( "handoff_context",
              `Assoc
                [
                  ("summary", `String "upstream PR already completed this scope");
                  ("reclaim_policy", `String "block_reclaim");
                ] );
          ])
    in
    if not (Tool_result.is_success release_result) then failwith (Tool_result.message release_result);
    assert_task_todo ctx;
    assert
      ((only_task ctx).do_not_reclaim_reason
       = Some "upstream PR already completed this scope");
    assert ((only_task ctx).reclaim_policy = Some Masc_domain.Block_reclaim);
    let reclaim_result =
      Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "claim");
          ])
    in
    assert (not (Tool_result.is_success reclaim_result));
    assert (str_contains (Tool_result.message reclaim_result) "blocked from re-claim"))
)

let () = test "dispatch_transition_claim_uses_server_surface_not_payload_surface" (fun () ->
  let ctx = make_test_ctx () in
  add_priority_task ctx ~title:"Needs bash";
  match
    Task.Tool.dispatch ctx
      ~name:"masc_transition"
      ~args:
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "claim");
          ])
  with
  | Some result ->
      assert (Tool_result.is_success result);
      assert_task_claimed_by ctx ctx.agent_name
  | None -> failwith "dispatch returned None"
)

let () = test "transition_release_clears_planning_current_task" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Transition release")]) in
  let claim_result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [("task_id", `String "task-001"); ("action", `String "claim")])
  in
  assert (Tool_result.is_success claim_result);
  let release_result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [("task_id", `String "task-001"); ("action", `String "release")])
  in
  assert (Tool_result.is_success release_result);
  assert (Planning_eio.get_current_task ctx.config = None)
)

let () = test "transition_done_completes_after_llm_review_and_clears_planning_current_task" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Transition done")]) in
  let claim_result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [("task_id", `String "task-001"); ("action", `String "claim")])
  in
  assert (Tool_result.is_success claim_result);
  let done_result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "done");
          ("notes", `String "Task scope satisfied: Transition done. Implemented the transport parity checks and verified the result. commit:abc123");
        ])
  in
  assert (Tool_result.is_success done_result);
  assert (not (str_contains (Tool_result.message done_result) "rejected"));
  assert (Planning_eio.get_current_task ctx.config = None);
  match Workspace.get_tasks_raw ctx.config with
  | [ task ] -> (
      match task.task_status with
      | Masc_domain.Done { assignee; _ } -> assert (String.equal assignee "test-agent")
      | other ->
        failwith
          (Printf.sprintf
             "expected task to be done after LLM review, got: %s"
             (Masc_domain.task_status_to_string other)))
  | _ -> failwith "expected exactly one task after done transition"
)

let () = test "transition_accepts_underscore_prefixed_internal_markers" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Marker test")]) in
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [
        ("task_id", `String "task-001");
        ("action", `String "claim");
        ("_agent_name", `String "dashboard");
        ("_session_marker", `String "sess-xyz");
      ])
  in
  assert (Tool_result.is_success result);
  assert (not (str_contains (Tool_result.message result) "Unknown argument"))
)

let () = test "transition_still_rejects_plain_unknown_arguments" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Reject test")]) in
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [
        ("task_id", `String "task-001");
        ("action", `String "claim");
        ("totally_bogus", `String "no");
      ])
  in
  assert (not (Tool_result.is_success result));
  assert (str_contains (Tool_result.message result) "Unknown argument(s): totally_bogus")
)

(* Test handle_done returns owner guidance when another agent owns the task *)
let () = test "handle_done_owned_by_other_guidance" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Done test")]) in
  let _ = Workspace.claim_task ctx.config ~agent_name:"other-agent" ~task_id:"task-001" in
  let result =
    Task.Tool.handle_done ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("task_id", `String "task-001"); ("notes", `String "")])
  in
  assert (not (Tool_result.is_success result));
  assert (str_contains (Tool_result.message result) "currently owned by other-agent")
)

(* Test handle_done on todo task recommends claim/start first *)
let () = test "handle_done_todo_guidance" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Todo test")]) in
  let result =
    Task.Tool.handle_done ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("task_id", `String "task-001"); ("notes", `String "")])
  in
  assert (not (Tool_result.is_success result));
  assert (str_contains (Tool_result.message result) "Claim/start it first");
  assert ((Tool_result.failure_class result) = Some Tool_result.Workflow_rejection);
  let data = Tool_result.data result in
  assert (Json_util.get_bool data "recoverable" = Some true);
  assert (
    match Json_util.assoc_member_opt "diagnosis" data with
    | Some diagnosis ->
      Json_util.get_string diagnosis "rule_id"
      = Some "task_done_requires_claimed_or_started"
      && Json_util.get_string diagnosis "tool_suggestion"
         = Some "masc_transition"
    | None -> false);
  assert (
    match Json_util.assoc_member_opt "alternatives" data with
    | Some (`List alternatives) ->
      List.exists (( = ) (`String "masc_transition")) alternatives
      && List.exists (( = ) (`String "keeper_task_claim")) alternatives
    | _ -> false)
)

(* Test handle_done reports already-done guidance instead of generic not-claimed *)
let () = test "handle_done_already_done_guidance" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Done test")]) in
  let _ = Workspace.claim_task ctx.config ~agent_name:"other-agent" ~task_id:"task-001" in
  let _ =
    Workspace.transition_task_r ctx.config ~agent_name:"other-agent"
      ~task_id:"task-001" ~action:Masc_domain.Done_action ~notes:"done" ()
  in
  let result =
    Task.Tool.handle_done ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("task_id", `String "task-001"); ("notes", `String "")])
  in
  assert (not (Tool_result.is_success result));
  assert (str_contains (Tool_result.message result) "already done by other-agent")
)

(* Test handle_done reports cancelled-task guidance instead of generic not-claimed *)
let () = test "handle_done_cancelled_guidance" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Cancelled test")]) in
  let _ = Workspace.cancel_task_r ctx.config ~agent_name:"test-agent" ~task_id:"task-001" ~reason:"stop" in
  let result =
    Task.Tool.handle_done ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("task_id", `String "task-001"); ("notes", `String "")])
  in
  assert (not (Tool_result.is_success result));
  assert (str_contains (Tool_result.message result) "was cancelled by test-agent")
)

(* Test dispatch transition release *)
let () = test "dispatch_transition_release" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("task_id", `String "task-001"); ("action", `String "release")] in
  match Task.Tool.dispatch ctx ~name:"masc_transition" ~args with
  | Some _ -> ()
  | None -> failwith "dispatch returned None"
)

(* Test dispatch transition *)
let () = test "dispatch_transition" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("task_id", `String "task-001"); ("action", `String "start")] in
  match Task.Tool.dispatch ctx ~name:"masc_transition" ~args with
  | Some _ -> ()
  | None -> failwith "dispatch returned None"
)

(* Test dispatch update_priority *)
let () = test "dispatch_update_priority" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("task_id", `String "task-001"); ("priority", `Int 1)] in
  match Task.Tool.dispatch ctx ~name:"masc_update_priority" ~args with
  | Some _ -> ()
  | None -> failwith "dispatch returned None"
)

(* Test dispatch task_history *)
let () = test "dispatch_task_history" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("task_id", `String "task-001")] in
  match Task.Tool.dispatch ctx ~name:"masc_task_history" ~args with
  | Some result -> assert (Tool_result.is_success result)
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
  let batch_result = Task.Tool.handle_batch_add_tasks ~tool_name:"test_tool" ~start_time:0.0 ctx args in
  assert (Tool_result.is_success batch_result)
)

let () = test "handle_batch_add_tasks_rejects_removed_role_fields" (fun () ->
  let ctx = make_test_ctx () in
  let args =
    `Assoc
      [
        ( "tasks",
          `List
            [
              `Assoc
                [
                  ("title", `String "Task 1");
                  ("required_role", `String "writer");
                ];
            ] );
      ]
  in
  let result = Task.Tool.handle_batch_add_tasks ~tool_name:"test_tool" ~start_time:0.0 ctx args in
  assert (not (Tool_result.is_success result));
  assert (str_contains (Tool_result.message result) "required_role is no longer supported")
)

let () = test "handle_batch_add_tasks_rejects_unknown_item_fields" (fun () ->
  let ctx = make_test_ctx () in
  let args =
    `Assoc
      [
        ( "tasks",
          `List
            [
              `Assoc
                [
                  ("title", `String "Task 1");
                  ("retired_tool_policy_field", `String "writer");
                ];
            ] );
      ]
  in
  let result = Task.Tool.handle_batch_add_tasks ~tool_name:"test_tool" ~start_time:0.0 ctx args in
  assert (not (Tool_result.is_success result));
  assert
    (str_contains (Tool_result.message result)
       "Unknown argument(s): retired_tool_policy_field")
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
(* The payload is built by Task.Tool.build_verdict_sse_payload —     *)
(* a pure helper — so dashboard subscribers depend on a stable       *)
(* JSON shape. The cross_runtime bool must match Eval_calibration's    *)
(* inclusion rule (both runtimes non-empty AND distinct).            *)
(* ================================================================ *)

let make_review_request () : Task.Anti_rationalization.review_request =
  { task_title = "Fix login bug";
    task_description = "desc";
    completion_notes = "notes";
    agent_name = "alice";
    task_id = "test-task-1" }

let make_review_result
    ?(verdict = Task.Anti_rationalization.Approve)
    ?(evaluator_runtime = "verifier")
    ?generator_runtime
    ?(gate = Task.Anti_rationalization.Structured_tool)
    ?fallback_reason
    () : Task.Anti_rationalization.review_result =
  { verdict; evaluator_runtime; generator_runtime; gate; fallback_reason }

let payload_member key (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields -> List.assoc "payload" fields |> (function
      | `Assoc payload_fields -> List.assoc key payload_fields
      | _ -> failwith "payload is not an object")
  | _ -> failwith "top-level is not an object"

let () = test "build_verdict_sse_payload: distinct runtimes = cross_runtime true" (fun () ->
  let req = make_review_request () in
  let result =
    make_review_result
      ~evaluator_runtime:"verifier"
      ~generator_runtime:Masc.(Keeper_config.default_runtime_id ())
      () in
  let json = Task.Tool.build_verdict_sse_payload
    ~now:1234567890.0 ~task_id:"t1" ~req ~result in
  assert (payload_member "cross_runtime" json = `Bool true);
  assert (payload_member "generator_runtime" json
          = `String Masc.(Keeper_config.default_runtime_id ()));
  assert (payload_member "evaluator_runtime" json = `String "verifier");
  assert (payload_member "task_id" json = `String "t1")
)

let () = test "build_verdict_sse_payload: same runtime = cross_runtime false" (fun () ->
  let req = make_review_request () in
  let result =
    make_review_result
      ~evaluator_runtime:"verifier"
      ~generator_runtime:"verifier"
      () in
  let json = Task.Tool.build_verdict_sse_payload
    ~now:1234567890.0 ~task_id:"t2" ~req ~result in
  assert (payload_member "cross_runtime" json = `Bool false);
  assert (payload_member "generator_runtime" json = `String "verifier")
)

let () = test "build_verdict_sse_payload: no generator = cross_runtime false + null" (fun () ->
  let req = make_review_request () in
  let result =
    make_review_result ~evaluator_runtime:"verifier" () in
  let json = Task.Tool.build_verdict_sse_payload
    ~now:1234567890.0 ~task_id:"t3" ~req ~result in
  assert (payload_member "cross_runtime" json = `Bool false);
  assert (payload_member "generator_runtime" json = `Null)
)

let () = test "build_verdict_sse_payload: empty generator string = cross_runtime false" (fun () ->
  (* Defensive: align with Eval_calibration which excludes empty
     strings from the denominator. Without this guard SSE and stats
     would disagree when a runtime is empty. *)
  let req = make_review_request () in
  let result =
    make_review_result
      ~evaluator_runtime:"verifier"
      ~generator_runtime:""
      () in
  let json = Task.Tool.build_verdict_sse_payload
    ~now:1234567890.0 ~task_id:"t4" ~req ~result in
  assert (payload_member "cross_runtime" json = `Bool false);
  assert (payload_member "generator_runtime" json = `String "")
)

let () = test "build_verdict_sse_payload: empty evaluator string = cross_runtime false" (fun () ->
  let req = make_review_request () in
  let result =
    make_review_result
      ~evaluator_runtime:""
      ~generator_runtime:Masc.(Keeper_config.default_runtime_id ())
      () in
  let json = Task.Tool.build_verdict_sse_payload
    ~now:1234567890.0 ~task_id:"t5" ~req ~result in
  assert (payload_member "cross_runtime" json = `Bool false)
)

let () = test "build_verdict_sse_payload: fallback_reason serialized" (fun () ->
  let req = make_review_request () in
  let result =
    make_review_result
      ~fallback_reason:"llm timeout"
      ~gate:Task.Anti_rationalization.Fallback
      () in
  let json = Task.Tool.build_verdict_sse_payload
    ~now:1234567890.0 ~task_id:"t6" ~req ~result in
  assert (payload_member "fallback_reason" json = `String "llm timeout");
  assert (payload_member "gate" json = `String "fallback")
)

(* Regression: claim_next should return no_unclaimed when all tasks are terminal (done/cancelled) *)
let () = test "claim_next_returns_no_unclaimed_when_all_tasks_terminal" (fun () ->
  let ctx = make_test_ctx () in
  (* Create a task, mark it as done *)
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Done task")]) in
  let _ = Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [
    ("task_id", `String "task-001");
    ("action", `String "done");
    ("notes", `String "Completed");
  ]) in
  (* Now try to claim next from a different agent in same workspace *)
  let agent2_ctx = make_test_ctx_with_agent "agent-2" in
  let msg_result = Task.Tool.handle_claim_next ~tool_name:"test_tool" ~start_time:0.0 agent2_ctx (`Assoc []) in
  (* Should report no unclaimed tasks (success=true, message contains "No") *)
  assert (String.length (Tool_result.message msg_result) > 0);
  match String.index_opt (Tool_result.message msg_result) 'N' with
  | Some _ -> () (* Found "No unclaimed" message *)
  | None -> failwith (Printf.sprintf "Expected 'No unclaimed' message, got: %s" (Tool_result.message msg_result))
)

(* Regression: claim_next should properly skip cancelled tasks and only claim todo *)
let () = test "claim_next_filters_out_cancelled_tasks" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Cancelled task")]) in
  let _ = Workspace.cancel_task_r ctx.config ~agent_name:ctx.agent_name ~task_id:"task-001" ~reason:"not needed" in
  let agent2_ctx = make_test_ctx_with_agent "agent-claim-2" in
  let msg_result = Task.Tool.handle_claim_next ~tool_name:"test_tool" ~start_time:0.0 agent2_ctx (`Assoc []) in
  match String.index_opt (Tool_result.message msg_result) 'N' with
  | Some _ -> () (* "No unclaimed" is correct *)
  | None -> failwith (Printf.sprintf "Expected no tasks available, got: %s" (Tool_result.message msg_result))
)

(* ===========================================================================
   RFC-0034.v2: per-goal cap propagation across all task creation entrypoints.
   See [docs/rfc/RFC-0034-cap-all-callers.md].

   The keeper-side regression for [keeper_task_create] (#13981) lives in
   [test_keeper_task_dispatch.ml:test_create_rejects_fourth_open_task_for_goal].
   The 4 tests below cover the remaining 4 entrypoints. Three of them
   currently invoke [Workspace_task.add_task] without a [goal_id], so the
   cap is by definition a no-op for them — the regression they pin is
   that the [reject_if] hook is wired and that orphan tasks pass.
   [masc_add_task] is the only entrypoint of the four that actually
   carries a [goal_id] today, so it is the one that exercises the
   rejection path end-to-end. *)

(* RFC-0034.v2 Test 1: masc_add_task (Task.Tool.handle_add_task) — the
   only orchestrating entrypoint that already accepts goal_id. *)
let () = test "rfc_0034_v2_masc_add_task_caps_per_goal" (fun () ->
  let ctx = make_test_ctx () in
  let goal, _ =
    match Goal_store.upsert_goal ctx.config ~title:"RFC-0034 cap goal" () with
    | Ok payload -> payload
    | Error msg -> failwith msg
  in
  for i = 1 to 3 do
    let msg_result =
      Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc
          [
            ("title", `String (Printf.sprintf "Goal task %d" i));
            ("description", `String "desc");
            ("priority", `Int 3);
            ("goal_id", `String goal.id);
          ])
    in
    if not (Tool_result.is_success msg_result)
    then
      failwith
        (Printf.sprintf
           "expected goal-bound add_task #%d to succeed, got: %s"
           i
           (Tool_result.message msg_result))
  done;
  let message_result =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("title", `String "Fourth goal task — should be rejected");
          ("description", `String "desc");
          ("priority", `Int 3);
          ("goal_id", `String goal.id);
        ])
  in
  (* The cap is enforced at persistence time. It must surface as a typed tool
     failure, not as a successful result carrying an ["Error: ..."] string. *)
  if Tool_result.is_success message_result
  then
    failwith
      (Printf.sprintf
         "expected fourth task to be rejected as workflow failure, got success: %s"
         (Tool_result.message message_result));
  if (Tool_result.failure_class message_result) <> Some Tool_result.Workflow_rejection
  then failwith "expected workflow_rejection failure_class";
  if not (str_starts_with ~prefix:"Error:" (Tool_result.message message_result))
  then
    failwith
      (Printf.sprintf
         "expected fourth task to be rejected with an \"Error:\" message, got: %s"
         (Tool_result.message message_result));
  if not (str_contains (Tool_result.message message_result) "goal_task_limit_exceeded")
  then
    failwith
      (Printf.sprintf
         "expected rejection message to mention goal_task_limit_exceeded, got: %s"
         (Tool_result.message message_result));
  let backlog = Workspace.read_backlog ctx.config in
  if List.length backlog.tasks <> 3
  then
    failwith
      (Printf.sprintf
         "expected exactly 3 persisted tasks (4th rejected), got %d"
         (List.length backlog.tasks)))

let () = test "handle_add_task_reports_goal_store_read_failure" (fun () ->
  let ctx = make_test_ctx () in
  corrupt_goal_store ctx.config;
  let result =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc
        [ "title", `String "Goal store read failure"
        ; "goal_id", `String "goal-corrupt"
        ])
  in
  if Tool_result.is_success result
  then failwith "expected goal store read failure to reject add_task";
  if Tool_result.failure_class result <> Some Tool_result.Runtime_failure
  then failwith "expected runtime_failure for goal store read failure";
  if not (str_contains (Tool_result.message result) "Goal store read failed:")
  then failwith ("unexpected message: " ^ Tool_result.message result))

let () = test "handle_add_task_validates_title_before_goal_store_read" (fun () ->
  let ctx = make_test_ctx () in
  corrupt_goal_store ctx.config;
  let result =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ "title", `String " "; "goal_id", `String "goal-corrupt" ])
  in
  if Tool_result.is_success result
  then failwith "expected blank title to reject add_task";
  if Tool_result.failure_class result <> Some Tool_result.Workflow_rejection
  then failwith "expected workflow_rejection for blank title";
  if str_contains (Tool_result.message result) "Goal store read failed:"
  then failwith ("goal store was consulted before title validation: " ^ Tool_result.message result))

let () = test "handle_set_goal_reports_goal_store_read_failure" (fun () ->
  let ctx = make_test_ctx () in
  let created =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ "title", `String "Task before corrupt goals" ])
  in
  if not (Tool_result.is_success created)
  then failwith ("expected seed task creation to succeed: " ^ Tool_result.message created);
  corrupt_goal_store ctx.config;
  let result =
    Task.Tool.handle_set_goal
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ "task_id", `String "task-001"; "goal_id", `String "goal-corrupt" ])
  in
  if Tool_result.is_success result
  then failwith "expected goal store read failure to reject set_goal";
  if Tool_result.failure_class result <> Some Tool_result.Runtime_failure
  then failwith "expected runtime_failure for set_goal read failure";
  if not (str_contains (Tool_result.message result) "failed to read goal store:")
  then failwith ("unexpected message: " ^ Tool_result.message result))

let () = test "handle_batch_add_tasks_reports_goal_store_read_failure" (fun () ->
  let ctx = make_test_ctx () in
  corrupt_goal_store ctx.config;
  let result =
    Task.Tool.handle_batch_add_tasks
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc
        [ ( "tasks"
          , `List
              [ `Assoc
                  [ "title", `String "Batch goal read failure"
                  ; "goal_id", `String "goal-corrupt"
                  ]
              ] )
        ])
  in
  if Tool_result.is_success result
  then failwith "expected goal store read failure to reject batch add";
  if Tool_result.failure_class result <> Some Tool_result.Runtime_failure
  then failwith "expected runtime_failure for batch goal store read failure";
  if not (str_contains (Tool_result.message result) "Goal store read failed:")
  then failwith ("unexpected message: " ^ Tool_result.message result))

let () = test "handle_batch_add_tasks_rejects_unknown_goal_id_as_workflow" (fun () ->
  let ctx = make_test_ctx () in
  let result =
    Task.Tool.handle_batch_add_tasks
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc
        [ ( "tasks"
          , `List
              [ `Assoc
                  [ "title", `String "Batch unknown goal"
                  ; "goal_id", `String "goal-missing"
                  ]
              ] )
        ])
  in
  if Tool_result.is_success result
  then failwith "expected unknown batch goal_id to reject batch add";
  if Tool_result.failure_class result <> Some Tool_result.Workflow_rejection
  then failwith "expected workflow_rejection for unknown batch goal_id";
  if not (str_contains (Tool_result.message result) "Unknown goal_id 'goal-missing'")
  then failwith ("unexpected message: " ^ Tool_result.message result))

(* RFC-0034.v2 Test 2: Task.Dispatch.add_task — orphan-only path today.
   Pins that the [reject_if] guard is wired AND non-blocking for orphan
   tasks even when the same goal is at the cap. *)
let () = test "rfc_0034_v2_task_dispatch_orphan_bypasses_cap" (fun () ->
  let ctx = make_test_ctx () in
  let goal, _ =
    match Goal_store.upsert_goal ctx.config ~title:"RFC-0034 dispatch goal" () with
    | Ok payload -> payload
    | Error msg -> failwith msg
  in
  for i = 1 to 3 do
    ignore
      (Workspace_task.add_task
         ~goal_id:goal.id
         ctx.config
         ~title:(Printf.sprintf "Goal-bound task %d" i)
         ~priority:3
         ~description:"desc")
  done;
  match
    Task.Dispatch.add_task ctx.config
      ~title:"Orphan dispatch task"
      ~priority:3
      ~description:"unbound"
  with
  | Ok msg when str_starts_with ~prefix:"Added " msg -> ()
  | Ok msg ->
      failwith
        (Printf.sprintf
           "task_dispatch orphan path should add (no goal_id), got: %s"
           msg)
  | Error err ->
      failwith
        (Printf.sprintf
           "task_dispatch orphan path returned Error: %s"
           (Masc_error.to_string err)))

(* RFC-0034.v2 Test 3: Mcp_tool_runtime_workspace — verified through
   direct Workspace_task.add_task with the same [reject_if] hook the
   MCP runtime wires. Confirms the [rejection_for_add_task ?goal_id:None]
   call shape compiles AND is non-blocking for orphan tasks. *)
let () = test "rfc_0034_v2_mcp_runtime_orphan_bypasses_cap" (fun () ->
  let ctx = make_test_ctx () in
  let goal, _ =
    match Goal_store.upsert_goal ctx.config ~title:"RFC-0034 inline goal" () with
    | Ok payload -> payload
    | Error msg -> failwith msg
  in
  for i = 1 to 3 do
    ignore
      (Workspace_task.add_task
         ~goal_id:goal.id
         ctx.config
         ~title:(Printf.sprintf "Pre-existing goal task %d" i)
         ~priority:3
         ~description:"desc")
  done;
  let result =
    Workspace_task.add_task
      ~reject_if:(Workspace_task_capacity.rejection_for_add_task ?goal_id:None)
      ctx.config
      ~title:"Inline-dispatched orphan task"
      ~priority:3
      ~description:""
  in
  if not (str_starts_with ~prefix:"Added " result)
  then
    failwith
      (Printf.sprintf
         "MCP-runtime orphan path should add, got: %s"
         result))

(* RFC-0034.v2 Test 4: operator_control task_inject — same shape as
   MCP runtime. Pins that the orphan-task call site does not
   regress to a rejection. *)
let () = test "rfc_0034_v2_operator_task_inject_orphan_bypasses_cap" (fun () ->
  let ctx = make_test_ctx () in
  let goal, _ =
    match Goal_store.upsert_goal ctx.config ~title:"RFC-0034 operator goal" () with
    | Ok payload -> payload
    | Error msg -> failwith msg
  in
  for i = 1 to 3 do
    ignore
      (Workspace_task.add_task
         ~goal_id:goal.id
         ctx.config
         ~title:(Printf.sprintf "Operator goal task %d" i)
         ~priority:3
         ~description:"desc")
  done;
  let result =
    Workspace.add_task
      ~reject_if:(Workspace_task_capacity.rejection_for_add_task ?goal_id:None)
      ctx.config
      ~title:"Operator-injected orphan"
      ~priority:2
      ~description:"Injected by operator control plane"
  in
  if not (str_starts_with ~prefix:"Added " result)
  then
    failwith
      (Printf.sprintf
         "operator task_inject orphan path should add, got: %s"
         result))

(* RFC-0034.v2 unit-level: capacity check helper on a goal-bound
   backlog. Pins the config-aware registry path used by task creation
   entrypoints. *)
let () = test "rfc_0034_v2_capacity_check_returns_some_at_limit" (fun () ->
  let ctx = make_test_ctx () in
  let goal, _ =
    match Goal_store.upsert_goal ctx.config ~title:"RFC-0034 unit goal" () with
    | Ok payload -> payload
    | Error msg -> failwith msg
  in
  for i = 1 to 3 do
    ignore
      (Workspace_task.add_task
         ~goal_id:goal.id
         ctx.config
         ~title:(Printf.sprintf "Unit-level goal task %d" i)
         ~priority:3
         ~description:"desc")
  done;
  let backlog = Workspace.read_backlog ctx.config in
  (match Workspace_task_capacity.check ?goal_id:None backlog with
   | None -> ()
   | Some _ ->
       failwith "orphan check (goal_id=None) should be a no-op");
  (match Workspace_task_capacity.check_for_config ctx.config ~goal_id:goal.id backlog with
   | Some err ->
       assert (err.open_task_count = 3);
       assert (err.limit = Workspace_task_capacity.default_goal_open_limit);
       assert (str_contains err.message "goal_task_limit_exceeded")
   | None ->
       failwith "expected capacity_error at the per-goal limit"))

let () =
  ensure_test_runtime ();
  Alcotest.run "Task.Tool"
    [
      ( "coverage",
        List.rev !test_cases
        |> List.map (fun (name, f) -> Alcotest.test_case name `Quick f) );
    ]
