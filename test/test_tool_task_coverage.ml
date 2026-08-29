module Types = Masc_domain

(** Coverage tests for Task.Tool *)

open Masc
module Planning_eio = Masc.Task.Planning_eio

let () = Random.self_init ()
let () = Mirage_crypto_rng_unix.use_default ()
let () = Workspace_metric_hooks.install ()
let () = Keeper_task_owner_backend.install_hooks ()

(* The completion-review path renders the registry prompt
   [verification]. This executable never pinned a
   markdown dir, so prompt resolution depended on whatever the host/dune
   context happened to expose — green on developer machines, "Prompt ...
   is missing" inside the CI dune sandbox, which failed every
   handle_done / handle_transition LLM-review case (quick-suite
   unmasking #24377). Pin resolution to the repo's own prompt files —
   the same idiom test_keeper_deliberation uses; that executable passes
   inside the CI sandbox, so the mechanism is CI-proven. *)
let has_prompt_root path =
  Sys.file_exists
    (Filename.concat path "config/prompts/verification.md")

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
      let rec ascend path =
        if has_prompt_root path then path
        else
          let parent = Filename.dirname path in
          if String.equal parent path then Sys.getcwd () else ascend parent
      in
      ascend (Sys.getcwd ())

let () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (repo_root ()) "config/prompts");
  Masc.Prompt_defaults.init ()

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
             Atomic.set Task.Handlers.push_event_to_sessions_fn (fun _ -> ());
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
  Prompt_registry.set_markdown_dir
    (Filename.concat (repo_root ()) "config/prompts");
  Atomic.set Workspace_hooks.get_default_runtime_id_fn Runtime.get_default_runtime_id;
  (* RFC-0361 D7(a): completion review resolves only the verifier_exact lane. *)
  Atomic.set
    Workspace_hooks.get_verifier_exact_lane_slot_ids_fn
    (fun () -> Ok [ "test-evaluator-runtime" ]);
  Atomic.set Task.Anti_rationalization.run_llm_reviewer_fn
    (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
       Ok (Some (Task.Anti_rationalization.Approve "")))

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
    with_env "MASC_BASE_PATH_INPUT" None (fun () -> f ()))

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

let seed_trace_evidence ctx trace_id =
  let base_path = ctx.Task.Tool.config.Workspace.base_path in
  let path =
    Filename.concat
      (Filename.concat
         (Filename.concat base_path ".masc")
         "trajectories/test-agent")
      (trace_id ^ ".jsonl")
  in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path
    {|{"type":"tool_task_coverage_evidence","turn":0,"trace_id":"test"}|}

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

let create_executing_goal ctx ~goal_id =
  match
    Goal_store.upsert_goal
      ctx.Task.Tool.config
      ~id:goal_id
      ~title:("Goal " ^ goal_id)
      ~metric:"m"
      ~target_value:"1"
      ~phase:Goal_phase.Executing
      ()
  with
  | Ok goal -> goal
  | Error message -> failwith message

let add_goal_linked_task ctx ~goal_id ~title =
  let result =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ "title", `String title; "goal_id", `String goal_id ])
  in
  if not (Tool_result.is_success result) then
    failwith (Tool_result.message result)

let keeper_transition ctx args =
  match
    Task.Tool.dispatch_for_keeper
      ~created_by:ctx.Task.Tool.agent_name
      ctx
      ~name:"masc_transition"
      ~args
  with
  | Some result -> result
  | None -> failwith "Keeper transition dispatch returned None"

let assert_goal_still_executing ctx ~goal_id =
  match Goal_store.get_goal ctx.Task.Tool.config ~goal_id with
  | Some { phase = Goal_phase.Executing; _ } -> ()
  | Some _ -> failwith "task completion must not mutate the linked Goal"
  | None -> failwith "linked Goal disappeared"

let register_test_keeper ctx ~keeper_name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String keeper_name);
          ("trace_id", `String ("test-trace-" ^ keeper_name));
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
        { backlog with
          tasks = [ { task with do_not_reclaim_reason = Some reason } ];
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

let verification_id_for_task ctx task_id =
  match
    Workspace.get_tasks_raw ctx.Task.Tool.config
    |> List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id)
  with
  | Some
      { task_status = Masc_domain.AwaitingVerification { verification_id; _ }; _ } ->
    verification_id
  | Some _ -> failwith (Printf.sprintf "task %s is not awaiting verification" task_id)
  | None -> failwith (Printf.sprintf "task %s not found" task_id)

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
        { backlog with tasks = [ { task with contract } ] }
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

let () = test "keeper dispatch keeps task author distinct from actor identity" (fun () ->
  let ctx = make_test_ctx_with_agent "fixture-keeper-agent" in
  let args = `Assoc [ ("title", `String "Keeper-authored task") ] in
  let result =
    Task.Tool.dispatch_for_keeper
      ~created_by:"fixture-keeper"
      ctx
      ~name:"masc_add_task"
      ~args
  in
  (match result with
   | Some result -> assert (Tool_result.is_success result)
   | None -> failwith "Keeper add-task dispatch returned None");
  match (Workspace.read_backlog ctx.config).tasks with
  | [ task ] -> assert (task.created_by = Some "fixture-keeper")
  | tasks ->
    failwith
      (Printf.sprintf "expected exactly one task, got %d" (List.length tasks)))

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

let () = test "handle_add_task_preserves_identical_titles_as_distinct_tasks" (fun () ->
  let ctx = make_test_ctx () in
  let first =
    Task.Tool.handle_add_task ~tool_name:"masc_add_task" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Duplicate contract task") ])
  in
  if not (Tool_result.is_success first) then failwith (Tool_result.message first);
  let second =
    Task.Tool.handle_add_task ~tool_name:"masc_add_task" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Duplicate contract task") ])
  in
  if not (Tool_result.is_success second) then failwith (Tool_result.message second);
  assert (Json_util.get_string (Tool_result.data first) "task_id" = Some "task-001");
  assert (Json_util.get_string (Tool_result.data second) "task_id" = Some "task-002");
  let backlog = Workspace.read_backlog ctx.config in
  assert (List.map (fun (task : Masc_domain.task) -> task.id) backlog.tasks
          = [ "task-001"; "task-002" ]);
  assert (List.map (fun (task : Masc_domain.task) -> task.title) backlog.tasks
          = [ "Duplicate contract task"; "Duplicate contract task" ]))

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

(* Regression for the self-author claim-path filter (issue #25459 / #25429):
   the auto-claim path in keeper_tool_task_runtime composes
   [not (task_is_self_authored_todo ~meta t)] into the [claim_next_r] hard
   filter so
   a keeper is not auto-assigned a task it authored itself. This exercises the
   real [claim_next_r] selection (the predicate itself is unit-tested in
   test_keeper_self_authored_task_exclusion). Ordering-independent: a single
   self-authored task is claimable without the filter and NOT claimable with
   it, so reverting the filter turns the second assertion RED. *)
let claimed_title = function
  | Masc_domain.Claim_next_claimed { title; _ } -> Some title
  | Masc_domain.Claim_next_no_unclaimed
  | Masc_domain.Claim_next_no_eligible _
  | Masc_domain.Claim_next_error _ -> None
;;

let () = test "auto_claim_takes_self_authored_task_without_filter" (fun () ->
  let ctx = make_test_ctx_with_agent "fixture-keeper" in
  let _ =
    Workspace.add_task_with_result ctx.Task.Tool.config
      ~created_by:"fixture-keeper" ~title:"self routing task" ~priority:1
      ~description:""
  in
  let result = Workspace.claim_next_r ctx.Task.Tool.config ~agent_name:"fixture-keeper" () in
  assert (claimed_title result = Some "self routing task"))

let () = test "auto_claim_self_author_filter_excludes_self_authored_task" (fun () ->
  let ctx = make_test_ctx_with_agent "fixture-keeper" in
  let _ =
    Workspace.add_task_with_result ctx.Task.Tool.config
      ~created_by:"fixture-keeper" ~title:"self routing task" ~priority:1
      ~description:""
  in
  let self_excluding (t : Masc_domain.task) = t.created_by <> Some "fixture-keeper" in
  let result =
    Workspace.claim_next_r ctx.Task.Tool.config ~agent_name:"fixture-keeper"
      ~hard_filter:self_excluding ()
  in
  assert (claimed_title result = None))

(* Regression for the adversarial P1 on #25460: the self-author exclusion must
   SURVIVE the scope fallback. The keeper auto-claim passes
   [allow_scope_fallback:true]; a keeper whose backlog holds only its own
   routing/report tasks has no goal-scoped task ([task_filter:(fun _ -> false)]
   forces that here), so [claim_next_r] widens — and the widening used to drop
   [task_filter], claiming the keeper's own task right back. With the exclusion
   moved to [hard_filter] the widening still respects it, so the own-task is NOT
   claimed. Reverting the exclusion back into [task_filter] turns this RED. *)
let () = test "auto_claim_hard_filter_survives_scope_fallback" (fun () ->
  let ctx = make_test_ctx_with_agent "fixture-keeper" in
  let _ =
    Workspace.add_task_with_result ctx.Task.Tool.config
      ~created_by:"fixture-keeper" ~title:"self routing task" ~priority:1
      ~description:""
  in
  let self_excluding (t : Masc_domain.task) = t.created_by <> Some "fixture-keeper" in
  let result =
    Workspace.claim_next_r ctx.Task.Tool.config ~agent_name:"fixture-keeper"
      ~task_filter:(fun _ -> false)
      ~hard_filter:self_excluding
      ~allow_scope_fallback:true ()
  in
  assert (claimed_title result = None))

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

(* A caller who states no completion criteria gets a task that says so. The
   handler used to fill the gap with "Task scope satisfied: <title>", which
   read as stated criteria to everything downstream while telling a verifier
   nothing. *)
let () = test "handle_add_task_omits_contract_when_unstated" (fun () ->
  let ctx = make_test_ctx () in
  let result =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("title", `String "Unstated criteria task");
          ("description", `String "Need verifier-visible evidence.");
        ])
  in
  if not (Tool_result.is_success result) then failwith (Tool_result.message result);
  match Workspace.get_tasks_raw ctx.config with
  | [ task ] -> (
      match task.contract with
      | None -> ()
      | Some contract ->
          failwith
            (Printf.sprintf
               "expected no contract, got completion_contract=[%s]"
               (String.concat "; " contract.completion_contract)))
  | _ -> failwith "expected exactly one task"
)

let () = test "handle_batch_add_tasks_omits_contract_when_unstated" (fun () ->
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
       | None -> ()
       | Some contract ->
           failwith
             (Printf.sprintf
                "expected no contract for %s, got completion_contract=[%s]"
                task.id
                (String.concat "; " contract.completion_contract)))
    tasks
)

(* Direct done and submitted verification share one configured-LLM review
   boundary. Contract shape does not create a second authorization lane. *)
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
                (* Was ["task-001"; "session:test"]. Neither is a form the
                   verification store can read, so both were snapshotted as
                   payload-free invalid references and this case asserted
                   success on evidence that is invisible at review. The
                   boundary now refuses them; the case keeps its subject
                   (strict release requires a handoff) with references that
                   survive to the reviewer. *)
                ( "evidence_refs",
                  `List
                    [ `String "note:task-001"
                    ; `String "note:session test transcript"
                    ] );
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

(* RFC-0337 decision 4: blank evidence_refs entries were silently dropped by
   [non_empty_trimmed_strings] (["", " "] collapsed to [] with no signal to
   the caller). The boundary now rejects blank entries loudly, mirroring the
   keeper_task_done parser; absent field and explicit [] stay accepted. *)
let () = test "handle_transition_rejects_blank_evidence_ref_entries" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Blank evidence entries task") ])
  in
  let _ = Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ ("task_id", `String "task-001") ]) in
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "release");
          ( "handoff_context",
            `Assoc
              [
                ("summary", `String "handing off with junk evidence entries");
                ("evidence_refs", `List [ `String ""; `String "  " ]);
              ] );
        ])
  in
  assert (not (Tool_result.is_success result));
  assert ((Tool_result.failure_class result) = Some Tool_result.Workflow_rejection);
  assert (str_contains (Tool_result.message result) "must contain only non-empty strings")
)

(* The same boundary rule for a reference the verification store cannot read.
   Accepting it snapshots a payload-free invalid reference, and the reviewer
   reads that as unavailable evidence — a verdict the submitter cannot act on
   because nothing names the reference form as the fault. Live: task-174 resent
   the same `board:p-…` entry and drew 59 rejections in two hours. *)
let () = test "handle_transition_rejects_unresolvable_evidence_ref_entries" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Unresolvable evidence task") ])
  in
  let _ = Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ ("task_id", `String "task-001") ]) in
  let reject reference =
    let result =
      Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "release");
            ( "handoff_context",
              `Assoc
                [
                  ("summary", `String "handing off");
                  ("evidence_refs", `List [ `String reference ]);
                ] );
          ])
    in
    assert (not (Tool_result.is_success result));
    assert ((Tool_result.failure_class result) = Some Tool_result.Workflow_rejection);
    assert (str_contains (Tool_result.message result) "note:<text>")
  in
  (* Every form the live workspace actually submitted and had rejected. *)
  reject "board:p-b8655a197dcf2f5da46655e10b3acbd1";
  reject "file:///Users/x/repo/out.diff";
  reject "https://github.com/o/r/pull/1";
  reject "artifacts/relative/but/unprefixed.md";
  reject "task-002:approved"
)

let () = test "handle_transition_accepts_resolvable_evidence_ref_forms" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Resolvable evidence task") ])
  in
  let _ = Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ ("task_id", `String "task-001") ]) in
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "release");
          ( "handoff_context",
            `Assoc
              [
                ("summary", `String "handing off");
                ( "evidence_refs"
                , `List
                    [ `String "artifact:out/report.md"
                    ; `String "note:board post p-b8655a19 carries the rationale"
                    ] );
              ] );
        ])
  in
  assert (Tool_result.is_success result)
)

let () = test "handle_transition_entry_action_rejects_blank_evidence_ref_entries" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Entry action blank evidence task") ])
  in
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "claim");
          ( "handoff_context",
            `Assoc
              [
                ("summary", `String "");
                ("evidence_refs", `List [ `String "  " ]);
              ] );
        ])
  in
  assert (not (Tool_result.is_success result));
  assert ((Tool_result.failure_class result) = Some Tool_result.Workflow_rejection);
  assert (str_contains (Tool_result.message result) "must contain only non-empty strings")
)

let () = test "handle_transition_accepts_explicit_empty_evidence_refs" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Explicit empty evidence task") ])
  in
  let _ = Task.Tool.handle_claim ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ ("task_id", `String "task-001") ]) in
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("task_id", `String "task-001");
          ("action", `String "release");
          ( "handoff_context",
            `Assoc
              [
                ("summary", `String "blocked, no evidence to hand off yet");
                ("evidence_refs", `List []);
              ] );
        ])
  in
  (* Explicit [] is "no evidence", not data loss — must not trip the
     blank-entry boundary reject. *)
  if not (Tool_result.is_success result) then failwith (Tool_result.message result)
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
  assert (str_contains (Tool_result.message result) "valid_next_actions");
  assert (str_contains (Tool_result.message result) "claim");
  (* The output must be a structured workflow rejection so the AGENT_CORE retry
     ladder treats it as deterministic non-retryable. *)
  let rejection_json = Tool_result.data result in
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
              "Invalid transition: todo -> start")
      task_entries
  with
  | Some entry ->
      assert (Log.level_to_string entry.level = "WARN")
  | None ->
      failwith "expected invalid transition to be logged through Task ring"
)

let () = test "handle_transition_release_by_nonowner_stays_tool-neutral"
    (fun () ->
  (* When a different agent claims the task, a release attempt by the
     non-owner must report the ownership mismatch without choosing the
     caller's next tool. *)
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
  let data = Tool_result.data result in
  assert (Json_util.get_string data "task_id" = Some "task-001");
  assert (Json_util.get_string data "current_assignee" = Some "owner-agent");
  assert (
    match Json_util.assoc_member_opt "diagnosis" data with
    | Some diagnosis ->
      Json_util.get_string diagnosis "rule_id"
      = Some "task_release_requires_current_owner"
    | None -> false)
)

let () = test "handle_transition_force_release_is_not_a_public_escape_hatch"
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
       assert (not (Tool_result.is_success result));
       assert (str_contains (Tool_result.message result) "Unknown argument(s): force");
       match
         Workspace.get_tasks_raw ctx_owner.Task.Tool.config
         |> List.find_opt (fun (task : Masc_domain.task) ->
              String.equal task.id "task-001")
       with
       | Some { task_status = Masc_domain.Claimed { assignee; _ }; _ }
         when String.equal assignee "owner-agent" -> ()
       | Some task ->
         failwith
           (Printf.sprintf
              "force must not change task ownership, got %s"
              (Masc_domain.task_status_to_string task.task_status))
       | None -> failwith "missing task-001 after rejected release escape hatch")
)

let () = test "handle_transition_submit_does_not_have_a_disable_bypass"
    (fun () ->
  let ctx = make_test_ctx_with_agent "owner-agent" in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ ("title", `String "Verification disabled gate") ])
  in
  start_task_001 ctx;
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
  assert (Tool_result.is_success result);
  match (only_task ctx).Masc_domain.task_status with
  | Masc_domain.AwaitingVerification _ -> ()
  | status ->
    failwith
      ("submit must remain available independent of a disable flag, got "
       ^ Masc_domain.task_status_to_string status)
)

let () = test "handle_transition_submit_rejects_registered_keeper_alias"
    (fun () ->
  (
    let ctx = make_test_ctx_with_agent "omega" in
    ignore
      (Workspace.bind_session ctx.config ~agent_name:"omega"
         ~capabilities:[] ());
    register_test_keeper ctx ~keeper_name:"omega";
    let _ =
      Task.Tool.handle_add_task
        ~tool_name:"test_tool"
        ~start_time:0.0
        ctx
        (`Assoc [ ("title", `String "Canonical submit identity") ])
    in
    (match
       Workspace.claim_task_r ctx.config ~agent_name:"omega"
         ~task_id:"task-001" ()
     with
     | Ok _ -> ()
     | Error err -> failwith (Masc_domain.masc_error_to_string err));
    let alias_ctx =
      { ctx with Task.Tool.agent_name = "keeper-omega" }
    in
    let result =
      Task.Tool.handle_transition
        ~tool_name:"test_tool"
        ~start_time:0.0
        alias_ctx
        (`Assoc
           [
             ("task_id", `String "task-001");
             ("action", `String "submit_for_verification");
             ( "notes",
               `String
                 "completion_notes: canonical identity submit test. \
                  reviewable_evidence_ref: artifact:canonical-submit.json" );
           ])
    in
    assert (not (Tool_result.is_success result));
    (* Pin the fact, not the phrasing: the refusal has to name the identity that
       actually owns the task, so a reader can tell an ownership rejection from
       an incidental FSM one. The old assertion pinned the literal "requires
       owning the task", which the message stopped using while still rejecting
       for exactly this reason. *)
    assert (str_contains (Tool_result.message result) "omega");
    assert_task_claimed_by ctx "omega"))

let () = test "keeper_reconciliation_ignores_prefix_matched_agent"
    (fun () ->
  let ctx = make_test_ctx_with_agent "codex-mcp-client" in
  let keeper_name = "omega" in
  let foreign_agent_name = "omega-shadow" in
  ignore
    (Workspace.bind_session
       ctx.config
       ~agent_name:foreign_agent_name
       ~capabilities:[]
       ());
  register_test_keeper ctx ~keeper_name;
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ "title", `String "Foreign prefix owner" ])
  in
  (match
     Workspace.claim_task_r
       ctx.config
       ~agent_name:foreign_agent_name
       ~task_id:"task-001"
       ()
   with
   | Ok _ -> ()
   | Error err -> failwith (Masc_domain.masc_error_to_string err));
  let meta =
    match Keeper_registry.get ~base_path:ctx.config.base_path keeper_name with
    | Some entry -> entry.meta
    | None -> failwith "registered keeper is missing"
  in
  (match
     Keeper_current_task_reconcile.owned_active_tasks_for_meta
       ~config:ctx.config
       ~meta
   with
   | Ok [] -> ()
   | Ok tasks ->
     failwith
       (Printf.sprintf
          "foreign prefix owner was treated as keeper ownership: %d task(s)"
          (List.length tasks))
   | Error detail -> failwith detail);
  let reconciled =
    Keeper_current_task_reconcile.sync_current_task_id_from_backlog
      ~config:ctx.config
      meta
  in
  assert (Option.is_none reconciled.current_task_id))

let () = test "keeper_reconciliation_accepts_short_keeper_identity"
    (fun () ->
  let ctx = make_test_ctx_with_agent "codex-mcp-client" in
  let keeper_name = "omega" in
  register_test_keeper ctx ~keeper_name;
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ "title", `String "Short keeper identity owner" ])
  in
  (match
     Workspace.claim_task_r
       ctx.config
       ~agent_name:keeper_name
       ~task_id:"task-001"
       ()
   with
   | Ok _ -> ()
   | Error err -> failwith (Masc_domain.masc_error_to_string err));
  let meta =
    match Keeper_registry.get ~base_path:ctx.config.base_path keeper_name with
    | Some entry -> entry.meta
    | None -> failwith "registered keeper is missing"
  in
  match
    Keeper_current_task_reconcile.owned_active_tasks_for_meta
      ~config:ctx.config
      ~meta
  with
  | Ok [ { task_id; _ } ] ->
    assert (String.equal (Keeper_id.Task_id.to_string task_id) "task-001")
  | Ok tasks ->
    failwith
      (Printf.sprintf
         "short keeper identity resolved %d owned tasks instead of one"
         (List.length tasks))
  | Error detail -> failwith detail)

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

(* Regression: 2026-05-17 theta0 production case. masc_transition with
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

let () = test "handle_transition_done_prefers_ownership_error_over_completion_gate" (fun () ->
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

let () = test "handle_transition_strict_done_reaches_lifecycle_submission_error" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [
          ("title", `String "Strict completion task");
          ( "contract",
            `Assoc
              [
                ("strict", `Bool true);
                ("completion_contract", `List [ `String "review required" ]);
              ] );
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
          ("notes", `String "review required");
        ])
  in
  assert (not (Tool_result.is_success result));
  assert
    (str_contains
       (Tool_result.message result)
       "Task completion must be submitted for verification");
  match (only_task ctx).Masc_domain.task_status with
  | Masc_domain.Claimed { assignee; _ } ->
    assert (String.equal assignee "test-agent")
  | status ->
    failwith
      ("strict direct done mutated task to "
       ^ Masc_domain.task_status_to_string status))

let () = test "handle_transition_force_is_not_a_done_action" (fun () ->
  let ctx = make_test_ctx_with_agent "admin-agent" in
  let add_result =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [ "title", `String "Forced Done LLM task" ])
  in
  if not (Tool_result.is_success add_result)
  then failwith (Tool_result.message add_result);
  start_task_001 ctx;
  let previous_is_admin = Atomic.get Workspace_hooks.is_admin_agent_fn in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.is_admin_agent_fn previous_is_admin)
    (fun () ->
       Atomic.set Workspace_hooks.is_admin_agent_fn
         (fun ~base_path:_ ~agent_name ->
            String.equal agent_name "admin-agent");
       let reviewer_called = ref false in
       Atomic.set Task.Anti_rationalization.run_llm_reviewer_fn
         (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
            reviewer_called := true;
            Ok (Some (Task.Anti_rationalization.Approve "")));
       let result =
         Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
           (`Assoc
             [ "task_id", `String "task-001"
             ; "action", `String "done"
             ; "force", `Bool true
             ; "notes", `String ""
             ])
       in
       assert (not (Tool_result.is_success result));
       assert
         (str_contains
            (Tool_result.message result)
            "Unknown argument(s): force");
       assert (not !reviewer_called);
       match (only_task ctx).Masc_domain.task_status with
       | Masc_domain.InProgress { assignee; _ } ->
         assert (String.equal assignee "admin-agent")
       | status ->
         failwith
           ("force argument on done must be rejected before completion review, got "
            ^ Masc_domain.task_status_to_string status)))

let () = test "handle_transition_done_on_awaiting_verification_is_explicit" (fun () ->
  (
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
    (* A strict submit must carry evidence (#23719/#23740 strict precheck) or
       the task never reaches AwaitingVerification and this test would assert
       against the precheck error instead (main red #23901, family A). *)
    let submitted =
      Workspace.transition_task_r ctx.config ~agent_name:"test-agent"
        ~task_id:"task-001" ~action:Masc_domain.Submit_for_verification
        ~notes:"strict contract verification setup notes"
        ~handoff_context:
          { Masc_domain.summary = "strict contract verification setup notes"
          ; reason = None
          ; next_step = None
          ; failure_mode = None
          ; reclaim_policy = None
          ; evidence_refs = [ "tests green: dune runtest" ]
          ; updated_at = None
          ; updated_by = None
          }
        ()
    in
    (match submitted with
     | Ok _ -> ()
     | Error e ->
       failwith
         ("setup submit should reach AwaitingVerification: "
          ^ Masc_domain.masc_error_to_string e));
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
    assert (str_contains (Tool_result.message result) "pending verification workflow");
    assert (str_contains (Tool_result.message result) "resolve it")))

let () = test "agent verdict verbs remain refused after terminal completion" (fun () ->
  let ctx = make_test_ctx_with_agent "worker" in
  let verifier_ctx = { ctx with Task.Tool.agent_name = "verifier" } in
  let _ = Workspace.add_task ctx.config ~title:"Already done" ~priority:1 ~description:"" in
  let _ = Workspace.claim_task ctx.config ~agent_name:"worker" ~task_id:"task-001" in
  let _ =
    Workspace.transition_task_r
      ctx.config
      ~agent_name:"worker"
      ~task_id:"task-001"
      ~action:Masc_domain.Start
      ()
  in
  let submitted =
    Workspace.transition_task_r ctx.config ~agent_name:"worker"
      ~task_id:"task-001" ~action:Masc_domain.Submit_for_verification ~notes:"complete" ()
  in
  (match submitted with
   | Ok _ -> ()
   | Error err -> failwith (Masc_domain.masc_error_to_string err));
  let done_result =
    Workspace.commit_verdict_r ctx.config
      ~authority:(Masc_domain.Human_operator { operator_id = "operator-test" })
      ~verdict:Masc_domain.Verdict_approved
      ~task_id:"task-001"
      ~verification_id:(verification_id_for_task ctx "task-001")
      ~notes:"complete"
      ()
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
      assert (not (Tool_result.is_success result));
      assert (str_contains (Tool_result.message result) "completion authority"))
    [ "approve"; "reject" ];
  match (only_task ctx).Masc_domain.task_status with
  | Masc_domain.Done _ -> ()
  | _ -> failwith "expected terminal task to stay done")

let () = test "operator verdict path replaces verifier agent actions" (fun () ->
  (
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
    let claim_result =
      Task.Tool.handle_claim
        ~tool_name:"keeper_task_claim"
        ~start_time:0.0
        verifier_ctx
        (`Assoc [ "task_id", `String "task-001" ])
    in
    assert (not (Tool_result.is_success claim_result));
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
    assert (not (Tool_result.is_success result));
    assert (str_contains (Tool_result.message result) "completion authority");
    let approved =
      Workspace.commit_verdict_r
        worker_ctx.config
        ~authority:(Masc_domain.Human_operator { operator_id = "operator-test" })
        ~verdict:Masc_domain.Verdict_approved
        ~task_id:"task-001"
        ~verification_id:(verification_id_for_task worker_ctx "task-001")
        ~notes:"evidence verified"
        ()
    in
    (match approved with
     | Ok _ -> ()
     | Error error -> failwith (Masc_domain.masc_error_to_string error));
    match (only_task worker_ctx).Masc_domain.task_status with
    | Masc_domain.Done _ -> ()
    | _ -> failwith "expected verifier approval to complete task"))

(* Refusing this transition left [Cancel] as the assignee's only move out of
   [AwaitingVerification]: the live backlog carried 16 refusals of
   "awaiting_verification -> submit_for_verification" and 10 cancellations whose
   stated reason was the deliverable. These four cases pin what makes the
   supersede safe rather than merely permitted. *)

let awaiting_snapshot ctx task_id =
  match
    Workspace.get_tasks_raw ctx.Task.Tool.config
    |> List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id)
  with
  | Some
      { task_status =
          Masc_domain.AwaitingVerification { verification_id; started_at; assignee; _ }
      ; _
      } -> verification_id, started_at, assignee
  | Some _ -> failwith (Printf.sprintf "task %s is not awaiting verification" task_id)
  | None -> failwith (Printf.sprintf "task %s not found" task_id)

let submit_for_verification ctx ~task_id ~notes =
  Task.Tool.handle_transition
    ~tool_name:"test_tool"
    ~start_time:0.0
    ctx
    (`Assoc
      [ "task_id", `String task_id
      ; "action", `String "submit_for_verification"
      ; "notes", `String notes
      ])

let resubmit_fixture () =
  let ctx = make_test_ctx_with_agent "worker" in
  let _ =
    Task.Tool.handle_add_task
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      (`Assoc [ "title", `String "Resubmittable deliverable" ])
  in
  let _ = Workspace.claim_task ctx.Task.Tool.config ~agent_name:"worker" ~task_id:"task-001" in
  let first =
    submit_for_verification
      ctx
      ~task_id:"task-001"
      ~notes:
        "completion_notes: first pass. reviewable_evidence_ref: \
         artifact:first-pass.json ready for review"
  in
  if not (Tool_result.is_success first) then failwith (Tool_result.message first);
  ctx

let () =
  test "resubmit supersedes the pending verification instead of discarding it" (fun () ->
    let ctx = resubmit_fixture () in
    let base_path = ctx.Task.Tool.config.Workspace.base_path in
    let first_id, first_started_at, _ = awaiting_snapshot ctx "task-001" in
    (match Verification.load_request base_path first_id with
     | Ok _ -> ()
     | Error detail -> failwith ("first request should exist: " ^ detail));
    let second =
      submit_for_verification
        ctx
        ~task_id:"task-001"
        ~notes:
          "completion_notes: second pass adds the missing benchmark. \
           reviewable_evidence_ref: artifact:second-pass.json ready for review"
    in
    if not (Tool_result.is_success second) then failwith (Tool_result.message second);
    let second_id, second_started_at, _ = awaiting_snapshot ctx "task-001" in
    (* A fresh id is what makes the supersede safe -- see the mismatch case
       below -- so equality here would defeat the whole design. *)
    assert (not (String.equal first_id second_id));
    (* The work began once, whatever the submission count. *)
    assert (String.equal first_started_at second_started_at);
    (match Verification.load_request base_path second_id with
     | Ok _ -> ()
     | Error detail -> failwith ("second request should exist: " ^ detail));
    match Verification.load_request base_path first_id with
    | Error _ -> ()
    | Ok _ ->
      failwith "superseded request should not survive: the task points only at the new id")

let () =
  test "a verdict on the superseded verification is refused" (fun () ->
    let ctx = resubmit_fixture () in
    let first_id, _, _ = awaiting_snapshot ctx "task-001" in
    let second =
      submit_for_verification
        ctx
        ~task_id:"task-001"
        ~notes:
          "completion_notes: second pass. reviewable_evidence_ref: \
           artifact:second-pass.json ready for review"
    in
    if not (Tool_result.is_success second) then failwith (Tool_result.message second);
    (* An in-flight judge reads its request once at the start, so it can return
       a verdict for evidence the task no longer carries. The id is what stops
       it landing. *)
    let stale =
      Workspace.commit_verdict_r
        ctx.Task.Tool.config
        ~authority:(Masc_domain.Human_operator { operator_id = "operator-test" })
        ~verdict:Masc_domain.Verdict_approved
        ~task_id:"task-001"
        ~verification_id:first_id
        ~notes:"approved against the superseded evidence"
        ()
    in
    (match stale with
     | Error _ -> ()
     | Ok _ -> failwith "a verdict carrying the superseded id must not complete the task");
    match (only_task ctx).Masc_domain.task_status with
    | Masc_domain.AwaitingVerification _ -> ()
    | _ -> failwith "task should still be awaiting its current verification")

let () =
  test "a verdict on the current verification still completes the task" (fun () ->
    let ctx = resubmit_fixture () in
    let second =
      submit_for_verification
        ctx
        ~task_id:"task-001"
        ~notes:
          "completion_notes: second pass. reviewable_evidence_ref: \
           artifact:second-pass.json ready for review"
    in
    if not (Tool_result.is_success second) then failwith (Tool_result.message second);
    let second_id, _, _ = awaiting_snapshot ctx "task-001" in
    let approved =
      Workspace.commit_verdict_r
        ctx.Task.Tool.config
        ~authority:(Masc_domain.Human_operator { operator_id = "operator-test" })
        ~verdict:Masc_domain.Verdict_approved
        ~task_id:"task-001"
        ~verification_id:second_id
        ~notes:"approved against the resubmitted evidence"
        ()
    in
    (match approved with
     | Ok _ -> ()
     | Error error -> failwith (Masc_domain.masc_error_to_string error));
    match (only_task ctx).Masc_domain.task_status with
    | Masc_domain.Done _ -> ()
    | _ -> failwith "expected the resubmitted verification to complete the task")

let () =
  test "only the assignee may supersede a pending verification" (fun () ->
    let ctx = resubmit_fixture () in
    let other_ctx = { ctx with Task.Tool.agent_name = "bystander" } in
    let first_id, _, _ = awaiting_snapshot ctx "task-001" in
    let result =
      submit_for_verification
        other_ctx
        ~task_id:"task-001"
        ~notes:
          "completion_notes: not my task. reviewable_evidence_ref: \
           artifact:bystander.json ready for review"
    in
    assert (not (Tool_result.is_success result));
    let unchanged_id, _, assignee = awaiting_snapshot ctx "task-001" in
    assert (String.equal first_id unchanged_id);
    assert (String.equal assignee "worker"))

let () =
  test "operator-approved verification leaves Goal action to durable reconciler"
    (fun () ->
       let worker_ctx = make_test_ctx_with_agent "worker" in
       let goal_id = "goal-approved-verification" in
       ignore (create_executing_goal worker_ctx ~goal_id);
       add_goal_linked_task
         worker_ctx
         ~goal_id
         ~title:"Complete through verification";
       ignore
         (Workspace.claim_task
            worker_ctx.config
            ~agent_name:"worker"
            ~task_id:"task-001");
       let submit_result =
         Task.Tool.handle_transition
           ~tool_name:"test_tool"
           ~start_time:0.0
           worker_ctx
           (`Assoc
              [ "task_id", `String "task-001"
              ; "action", `String "submit_for_verification"
              ; ( "notes"
                , `String
                    "completion_notes: implementation complete. \
                     reviewable_evidence_ref: artifact:goal-cue.json"
                )
              ])
       in
       if not (Tool_result.is_success submit_result) then
         failwith (Tool_result.message submit_result);
       let result =
         Workspace.commit_verdict_r
           worker_ctx.config
           ~authority:
             (Masc_domain.Human_operator { operator_id = "operator-test" })
           ~verdict:Masc_domain.Verdict_approved
           ~task_id:"task-001"
           ~verification_id:(verification_id_for_task worker_ctx "task-001")
           ~notes:"evidence verified"
           ()
       in
       (match result with
        | Ok _ -> ()
        | Error error -> failwith (Masc_domain.masc_error_to_string error));
       assert_goal_still_executing worker_ctx ~goal_id)

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
    (Workspace.bind_session ctx.config ~agent_name:"omega"
       ~capabilities:[] ());
  register_test_keeper ctx ~keeper_name:"omega";
  let keeper_ctx = { ctx with Task.Tool.agent_name = "omega" } in
  let result =
    Task.Tool.handle_claim
      ~tool_name:"test_tool"
      ~start_time:0.0
      keeper_ctx
      (`Assoc [ ("task_id", `String "task-002") ])
  in
  assert (Tool_result.is_success result);
  assert (Planning_eio.get_current_task ctx.config = Some "task-001"))

let () = test "keeper_alias_claim_updates_planning_as_exact_agent" (fun () ->
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
    (Workspace.bind_session ctx.config ~agent_name:"keeper-omega-agent"
       ~capabilities:[] ());
  register_test_keeper ctx ~keeper_name:"omega";
  let keeper_ctx =
    { ctx with Task.Tool.agent_name = "keeper-omega" }
  in
  let result =
    Task.Tool.handle_claim
      ~tool_name:"test_tool"
      ~start_time:0.0
      keeper_ctx
      (`Assoc [ ("task_id", `String "task-002") ])
  in
  assert (Tool_result.is_success result);
  assert (Planning_eio.get_current_task ctx.config = Some "task-002"))

let () = test "keeper_generated_alias_claim_updates_planning_as_exact_agent" (fun () ->
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
    (Workspace.bind_session ctx.config ~agent_name:"keeper-omega-agent"
       ~capabilities:[] ());
  ignore
    (Workspace.bind_session ctx.config ~agent_name:"keeper-omega-warm-raven-agent"
       ~capabilities:[] ());
  register_test_keeper ctx ~keeper_name:"omega";
  let keeper_ctx =
    { ctx with Task.Tool.agent_name = "keeper-omega-warm-raven-agent" }
  in
  let result =
    Task.Tool.handle_claim
      ~tool_name:"test_tool"
      ~start_time:0.0
      keeper_ctx
      (`Assoc [ ("task_id", `String "task-002") ])
  in
  assert (Tool_result.is_success result);
  assert (Planning_eio.get_current_task ctx.config = Some "task-002"))

let () = test "keeper_separator_alias_claim_updates_planning_as_exact_agent" (fun () ->
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
    (Workspace.bind_session ctx.config ~agent_name:"keeper-pi-glutton-agent"
       ~capabilities:[] ());
  ignore
    (Workspace.bind_session ctx.config ~agent_name:"keeper-pi_glutton-agent"
       ~capabilities:[] ());
  register_test_keeper ctx ~keeper_name:"pi-glutton";
  let keeper_ctx =
    { ctx with Task.Tool.agent_name = "keeper-pi_glutton-agent" }
  in
  let result =
    Task.Tool.handle_claim
      ~tool_name:"test_tool"
      ~start_time:0.0
      keeper_ctx
      (`Assoc [ ("task_id", `String "task-002") ])
  in
  assert (Tool_result.is_success result);
  assert (Planning_eio.get_current_task ctx.config = Some "task-002"))

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
  (* This asserted "task(s) in progress: task-001", the wording of the by-id
     refusal before it shared claim_next's sentence. What it was pinning -- that
     the refusal names the Task actually held -- is unchanged. *)
  assert (str_contains (Tool_result.message second) "already holds");
  assert (str_contains (Tool_result.message second) "task-001");
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

let () = test "handle_claim_next_accepts_open_claims" (fun () ->
  let keeper_name = "social-sync" in
  let agent_name = keeper_name in
  let ctx = make_test_ctx_with_agent agent_name in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("trace_id", `String "trace-social-sync");
          ])
    with
    | Ok meta -> meta
    | Error e -> failwith ("meta_of_json failed: " ^ e)
  in
  (match Keeper_meta_store.replace_snapshot ctx.config initial_meta with
  | Ok () -> ()
  | Error e -> failwith ("write_meta failed: " ^ e));
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
    | None -> false);
  assert (str_contains (Tool_result.message result) "absent from the live backlog")
)

let () = test "keeper transition rejection stays tool-neutral" (fun () ->
  let ctx = make_test_ctx () in
  let result =
    Task.Tool.dispatch_for_keeper
      ~created_by:ctx.agent_name
      ctx
      ~name:"masc_transition"
      ~args:
        (`Assoc
           [ "task_id", `String "task-1468"; "action", `String "start" ])
  in
  match result with
  | None -> failwith "Keeper transition dispatch returned None"
  | Some result ->
    assert (not (Tool_result.is_success result));
    let data = Tool_result.data result in
    (match Json_util.assoc_member_opt "diagnosis" data with
     | Some diagnosis ->
       assert
         (Json_util.get_string diagnosis "rule_id"
          = Some "stale_task_id_not_found");
       assert (Json_util.assoc_member_opt "tool_suggestion" diagnosis = None)
     | None -> failwith "missing Keeper transition diagnosis");
    assert (Json_util.assoc_member_opt "alternatives" data = None))

(* Submit-for-verification is tested as a lifecycle transition here. Evidence
   text and references are transported to the verifier; this layer does not
   classify their semantic sufficiency. *)

let task_submit_evidence_notes =
  "completion_notes: implementation completed with verification context. \
   reviewable_evidence_ref: review evidence is attached."

let () = test "transition_submit_for_verification_todo_rejects_instead_of_alias" (fun () ->
  (
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
    assert
      (str_contains
         (Tool_result.message result)
         "Invalid transition: todo -> submit_for_verification");
    (* Order follows [Masc_domain.all_task_actions], which the hint is now
       derived from, rather than the hand-written order it used to restate.
       [release] left this list: it is admitted from Todo and returns it
       unchanged, and the hint lists what moves the Task. *)
    assert (str_contains (Tool_result.message result) "valid_next_actions=[claim;cancel]");
    assert_task_todo ctx)
)

let () = test "transition_submit_pr_evidence_is_retired" (fun () ->
  (
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

(* No local substring or reference-shape gate is asserted for submission.
   Verification sufficiency belongs to the verifier decision boundary. *)

let () = test "transition_claim_clears_legacy_cycle_do_not_reclaim_reason" (fun () ->
  (
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
  (
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

(* RFC-0323 G-10 (+ #23661): the typed reclaim claim gate is retired. A
   block_reclaim release persists policy + reason as operator-facing data,
   but the recycled Todo is claimable again. *)
let () = test "transition_release_block_reclaim_data_survives_reclaim" (fun () ->
  (
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
    if not (Tool_result.is_success reclaim_result)
    then failwith (Tool_result.message reclaim_result);
    (* Block_reclaim + reason survive the claim as operator context. *)
    assert ((only_task ctx).reclaim_policy = Some Masc_domain.Block_reclaim);
    assert
      ((only_task ctx).do_not_reclaim_reason
       = Some "upstream PR already completed this scope"))
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

let () = test "transition_rejects_caller_controlled_agent_name" (fun () ->
  let ctx = make_test_ctx () in
  let _ =
    Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc [("title", `String "Identity contract test")])
  in
  let result =
    Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx
      (`Assoc
        [ ("task_id", `String "task-001")
        ; ("action", `String "claim")
        ; ("agent_name", `String "another-agent")
        ])
  in
  assert (not (Tool_result.is_success result));
  assert
    (str_contains
       (Tool_result.message result)
       "Unknown argument(s): agent_name")
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

(* Test handle_done on a todo task reports typed state without choosing a tool. *)
let () = test "handle_done_todo_rejection_is_tool-neutral" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Todo test")]) in
  let result =
    Task.Tool.handle_done ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("task_id", `String "task-001"); ("notes", `String "")])
  in
  assert (not (Tool_result.is_success result));
  assert (str_contains (Tool_result.message result) "still todo");
  assert ((Tool_result.failure_class result) = Some Tool_result.Workflow_rejection);
  let data = Tool_result.data result in
  assert (Json_util.get_bool data "recoverable" = Some true);
  assert (
    match Json_util.assoc_member_opt "diagnosis" data with
    | Some diagnosis ->
      Json_util.get_string diagnosis "rule_id"
      = Some "task_done_requires_claimed_or_started"
    | None -> false);
  assert (Json_util.assoc_member_opt "alternatives" data = None)
)

(* Test handle_done reports already-done guidance instead of generic not-claimed *)
let () = test "handle_done_already_done_guidance" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Done test")]) in
  let _ = Workspace.claim_task ctx.config ~agent_name:"other-agent" ~task_id:"task-001" in
  let _ =
    Workspace.transition_task_r ctx.config ~agent_name:"other-agent"
      ~task_id:"task-001" ~action:Masc_domain.Start ()
  in
  let _ =
    Workspace.transition_task_r ctx.config ~agent_name:"other-agent"
      ~task_id:"task-001" ~action:Masc_domain.Submit_for_verification ~notes:"done" ()
  in
  let _ =
    Workspace.commit_verdict_r ctx.config
      ~authority:(Masc_domain.Human_operator { operator_id = "operator-test" })
      ~verdict:Masc_domain.Verdict_approved
      ~task_id:"task-001"
      ~verification_id:(verification_id_for_task ctx "task-001")
      ~notes:"done"
      ()
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
  let _ = Workspace.transition_task_r ctx.config ~agent_name:"test-agent" ~task_id:"task-001" ~action:Masc_domain.Cancel ~reason:"stop" () in
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

let () = test "handle_batch_add_tasks_rejects_removed_contract_field" (fun () ->
  let ctx = make_test_ctx () in
  let args =
    `Assoc
      [ ( "tasks"
        , `List
            [ `Assoc
                [ "title", `String "Task 1"
                ; "contract", `Assoc [ "links", `Assoc [] ]
                ]
            ] )
      ]
  in
  let result =
    Task.Tool.handle_batch_add_tasks
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      args
  in
  assert (not (Tool_result.is_success result));
  assert
    (str_contains
       (Tool_result.message result)
       "contract contains unsupported field links"))

let () = test "handle_batch_add_tasks_rejects_duplicate_contract_field" (fun () ->
  let ctx = make_test_ctx () in
  let args =
    `Assoc
      [ ( "tasks"
        , `List
            [ `Assoc
                [ "title", `String "Task 1"
                ; ( "contract"
                  , `Assoc [ "strict", `Bool true; "strict", `Bool false ] )
                ]
            ] )
      ]
  in
  let result =
    Task.Tool.handle_batch_add_tasks
      ~tool_name:"test_tool"
      ~start_time:0.0
      ctx
      args
  in
  assert (not (Tool_result.is_success result));
  assert
    (str_contains
       (Tool_result.message result)
       "contract contains duplicate field strict"))

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

(* Regression: claim_next should return no_unclaimed when all tasks are terminal (done/cancelled) *)
let () = test "claim_next_returns_no_unclaimed_when_all_tasks_terminal" (fun () ->
  let ctx = make_test_ctx () in
  (* Create a task, mark it as done *)
  let _ = Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [("title", `String "Done task")]) in
  seed_trace_evidence ctx "done-task";
  let _ = Task.Tool.handle_transition ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [
    ("task_id", `String "task-001");
    ("action", `String "done");
    ("notes", `String "Completed");
    (* Evidence is included as LLM context. The test hook's approval is the
       completion verdict that places this task in its terminal state. *)
    ("handoff_context", `Assoc [
      ("summary", `String "Done task completed");
      ("evidence_refs", `List [ `String "trace:done-task" ]);
    ]);
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
  let _ = Workspace.transition_task_r ctx.config ~agent_name:ctx.agent_name ~task_id:"task-001" ~action:Masc_domain.Cancel ~reason:"not needed" () in
  let agent2_ctx = make_test_ctx_with_agent "agent-claim-2" in
  let msg_result = Task.Tool.handle_claim_next ~tool_name:"test_tool" ~start_time:0.0 agent2_ctx (`Assoc []) in
  match String.index_opt (Tool_result.message msg_result) 'N' with
  | Some _ -> () (* "No unclaimed" is correct *)
  | None -> failwith (Printf.sprintf "Expected no tasks available, got: %s" (Tool_result.message msg_result))
)

let () =
  test "strict verdict validates justification and credits producer metrics" (fun () ->
    let ctx = make_test_ctx_with_agent "producer" in
    let verifier_ctx = { ctx with Task.Tool.agent_name = "verifier" } in
    add_priority_task ctx ~title:"Strict completion metrics";
    set_only_task_contract
      ctx
      (Some (make_task_contract ~strict:true ()));
    start_task_001 ctx;
    let submitted =
      Task.Tool.handle_transition
        ~tool_name:"test_tool"
        ~start_time:0.0
        ctx
        (`Assoc
          [ "task_id", `String "task-001"
          ; "action", `String "submit_for_verification"
          ; "notes", `String "producer evidence is ready"
          ])
    in
    if not (Tool_result.is_success submitted)
    then failwith (Tool_result.message submitted);
    let expect_still_awaiting () =
      match (only_task ctx).Masc_domain.task_status with
      | Masc_domain.AwaitingVerification _ -> ()
      | _ -> failwith "a refused verdict request must not mutate the obligation"
    in
    (* No peer-keeper claim step: an obligation is not claimable. And the agent
       tool surface refuses the verdict verbs outright — the message must name the
       completion authority rather than report an unknown action, so an agent that
       asks learns why it cannot. *)
    List.iter
      (fun verb ->
         let refused =
           Task.Tool.handle_transition
             ~tool_name:"test_tool"
             ~start_time:0.0
             verifier_ctx
             (`Assoc [ "task_id", `String "task-001"; "action", `String verb ])
         in
         assert (not (Tool_result.is_success refused));
         assert (str_contains (Tool_result.message refused) "completion authority");
         expect_still_awaiting ())
      [ "approve"; "reject" ];
    let previous_metric = Atomic.get Workspace_hooks.record_task_metric_fn in
    let metric_events = ref [] in
    Fun.protect
      ~finally:(fun () ->
        Atomic.set Workspace_hooks.record_task_metric_fn previous_metric)
      (fun () ->
        Atomic.set Workspace_hooks.record_task_metric_fn
          (fun _config
               ~agent_id
               ~task_id:_
               ~started_at:_
               ~completed_at:_
               ~success
               ~error_message:_
               ~collaborators
               ~handoff_from:_
               ~handoff_to:_ ->
             metric_events := (agent_id, success, collaborators) :: !metric_events);
        let approved =
          Workspace.commit_verdict_r
            ctx.config
            ~authority:(Masc_domain.Human_operator { operator_id = "operator-test" })
            ~verdict:Masc_domain.Verdict_approved
            ~task_id:"task-001"
            ~verification_id:(verification_id_for_task ctx "task-001")
            ~notes:"tests and evidence verified"
            ()
        in
        match approved with
        | Ok _ -> ()
        | Error error -> failwith (Masc_domain.masc_error_to_string error));
    (* Credited to the producer with no collaborators: the authority is not an
       agent, so it never enters the collaborator set. *)
    assert (List.mem ("producer", true, []) !metric_events))
;;

(* The action list reaches the model twice: as the enum, derived from
   [Masc_domain.valid_task_action_strings], and as the property description.
   The description used to spell the same six names out by hand, which put
   "done" in front of the model as one ordinary option among them.

   It is not one. The lifecycle answers Done_action with
   Verification_submission_required from Claimed and InProgress, and with
   Invalid_transition from Todo, AwaitingVerification and Cancelled — every
   status a Keeper can be working. Only Done->Done succeeds, as a no-op.
   Measured over the live tool log: 111 calls passed action="done", 70 errored,
   and the remaining 41 were that no-op.

   Pinned from two sides. The enum must still carry every action the type has,
   because that is what the dispatcher accepts; the description must not
   re-list them, because a hand-written copy of a derived list is what drifted. *)
let () = test "transition action description does not re-list the enum" (fun () ->
  let schema =
    List.find
      (fun (s : Masc_domain.tool_schema) -> String.equal s.name "masc_transition")
      Masc.Task.Schemas.schemas
  in
  let action_description =
    match schema.input_schema with
    | `Assoc top ->
      (match List.assoc "properties" top with
       | `Assoc props ->
         (match List.assoc "action" props with
          | `Assoc action ->
            (match List.assoc "description" action with
             | `String d -> d
             | _ -> failwith "action description is not a string")
          | _ -> failwith "action property is not an object")
       | _ -> failwith "properties is not an object")
    | _ -> failwith "input_schema is not an object"
  in
  let contains needle =
    let n = String.length needle and h = String.length action_description in
    let rec loop i =
      i + n <= h && (String.sub action_description i n = needle || loop (i + 1))
    in
    loop 0
  in
  (* The pipe-separated copy of the enum is gone. *)
  assert (not (contains "claim | start"));
  (* done is named, and named as refused rather than offered. *)
  assert (contains "done is refused");
  (* The route that does complete a Task is the one stated. *)
  assert (contains "submit_for_verification");
  (* The enum keeps every action the dispatcher accepts, done included. *)
  let enum_actions =
    match schema.input_schema with
    | `Assoc top ->
      (match List.assoc "properties" top with
       | `Assoc props ->
         (match List.assoc "action" props with
          | `Assoc action ->
            (match List.assoc "enum" action with
             | `List xs ->
               List.filter_map (function `String s -> Some s | _ -> None) xs
             | _ -> failwith "enum is not a list")
          | _ -> failwith "action property is not an object")
       | _ -> failwith "properties is not an object")
    | _ -> failwith "input_schema is not an object"
  in
  assert (
    List.sort compare enum_actions
    = List.sort compare Masc_domain.valid_task_action_strings))
;;

(* [claim_next] and a claim by task_id refuse the same limit. Only [claim_next]
   named the route; the by-id path said "has task(s) in progress: task-149;
   task-148 was not claimed." and stopped -- and that is the path Keepers hit,
   38 of the week's 77 claim rejections. The three tokens asserted here are the
   same three test_workspace_coverage pins on the [claim_next] message, so the
   two cannot drift apart again. *)
let () =
  test "a claim-by-id refusal names the release route, as claim_next does"
    (fun () ->
       let ctx = make_test_ctx_with_agent "worker" in
       List.iter
         (fun title ->
            ignore
              (Task.Tool.handle_add_task
                 ~tool_name:"test_tool"
                 ~start_time:0.0
                 ctx
                 (`Assoc [ "title", `String title ])))
         [ "Held work"; "Tempting other work" ];
       let held =
         Task.Tool.handle_claim
           ~tool_name:"keeper_task_claim"
           ~start_time:0.0
           ctx
           (`Assoc [ "task_id", `String "task-001" ])
       in
       if not (Tool_result.is_success held) then failwith (Tool_result.message held);
       let refused =
         Task.Tool.handle_claim
           ~tool_name:"keeper_task_claim"
           ~start_time:0.0
           ctx
           (`Assoc [ "task_id", `String "task-002" ])
       in
       assert (not (Tool_result.is_success refused));
       let message = Tool_result.message refused in
       assert (str_contains message "task-001");
       assert (str_contains message "Held work");
       assert (str_contains message "masc_transition");
       assert (str_contains message "action=release");
       assert (str_contains message "handoff_context.summary"))

(* The message tells the assignee to release, so Release has to be admitted from
   every status that can produce the refusal. [active_owned_task_ids_for_agent]
   returns exactly Claimed and InProgress, so those are the two to pin: an FSM
   change that stopped admitting Release would land here rather than as advice
   Keepers cannot follow. *)
let () =
  test "release is admitted from every status that can trigger that refusal"
    (fun () ->
       List.iter
         (fun status ->
            let actions =
              Workspace_task_lifecycle.valid_next_actions ~same_agent:true
                ~task_status:status
            in
            if not (List.exists (( = ) Masc_domain.Release) actions)
            then
              failwith
                (Printf.sprintf
                   "Release must stay admitted from %s, or the ownership refusal \
                    names an action the assignee cannot take"
                   (Masc_domain.task_status_to_string status)))
         [ Masc_domain.Claimed { assignee = "worker"; claimed_at = "t" }
         ; Masc_domain.InProgress { assignee = "worker"; started_at = "t" }
         ])

(* [limit] counts THIS task's events. Counting raw lines instead meant the
   reader budgeted [min 500 (limit * 5)] lines and filtered afterwards, so a
   task whose events sit behind a busier task's fell out of its own history:
   at limit=5 the budget was 25 lines, and 30 later events from another task
   consumed all of them. *)
let () = test "task_history_counts_matches_not_lines" (fun () ->
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
        [ ("task_id", `String task_id)
        ; ("action", `String action)
        ; ("ts", `Float (gettimeofday ()))
        ])
  in
  Fs_compat.append_file log_file (event "quiet-task" "claim" ^ "\n");
  Fs_compat.append_file log_file (event "quiet-task" "done" ^ "\n");
  for i = 1 to 30 do
    Fs_compat.append_file log_file
      (event "busy-task" (Printf.sprintf "step-%d" i) ^ "\n")
  done;
  let rows json =
    match json with
    | `List rows -> rows
    | _ -> failwith "task history payload must be a JSON list"
  in
  let quiet =
    rows (Task.Tool.task_history_events_json ctx.config ~task_id:"quiet-task" ~limit:5)
  in
  assert (List.length quiet = 2);
  let busy =
    rows (Task.Tool.task_history_events_json ctx.config ~task_id:"busy-task" ~limit:5)
  in
  assert (List.length busy = 5)
)

let () =
  ensure_test_runtime ();
  Alcotest.run "Task.Tool"
    [
      ( "coverage",
        List.rev !test_cases
        |> List.map (fun (name, f) -> Alcotest.test_case name `Quick f) );
    ]
