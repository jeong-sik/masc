open Masc
module AR = Task.Anti_rationalization
module V = Verifier_review_original
module O = Verifier_review_owner
module P = Lane_addon_request_progress
module X = Verifier_review_execution
module W = Verifier_review_worker
module Walk_result = Verifier_review_walk_result

let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let retained = function
  | Ok () -> ()
  | Error (O.Original_invalid detail | Identity_mismatch detail
    | Retain_store_unavailable detail | Already_retained detail) ->
    Alcotest.fail ("original retain failed: " ^ detail)
let owner = function
  | Ok value -> value
  | Error (O.Load_store_unavailable detail | Corrupt_original detail) ->
    Alcotest.fail ("original owner unavailable: " ^ detail)
  | Error O.Not_found -> Alcotest.fail "original owner not found"
let verification_id = "vrf-journal-recovery"
let installation_id = "fixture.verifier"
let package_id = "fixture.review"
let model_id = "review-execution-fixture"

let make_original () =
  V.prepare ~generator_runtime:None ~verification_id ~attempt:0
    ~question:{AR.completion_contract=None;required_evidence=[];evidence_posture=AR.Note_only;few_shot_block=""}
    ~lookup_root:(AR.Producer_namespace {root="/declared/producer"})
    ~lookup_binding:(String.make 64 'a') ~lookup_schemas:["tool_read_file"]
    {AR.task_title="T";task_description="D";completion_notes="N";agent_name="producer";
      task_id="task-001";evidence_refs=[];evidence_images=[]} |> get

let with_runtime f = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  Runtime_agent_execution_runtime.initialize ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
    |> Result.map_error Runtime_agent_execution_runtime.initialization_error_to_string |> get;
  Eio.Switch.on_release sw Fs_compat.clear_fs;
  let previous = Llm_provider.Catalog_snapshot.current () in
  Eio.Switch.on_release sw (fun () -> Llm_provider.Catalog_snapshot.publish previous);
  let source = Printf.sprintf
    "[[models]]\nmodel_id = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_native_streaming = false\n" model_id in
  Llm_provider.Model_catalog.of_toml_string ~source:"review-journal-test" source
    |> get |> (fun models -> Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some models) ~providers:(None)));
  f env sw))

let store_of ~base_path = Lane_addon_store.create
  ~root:(Filename.concat (Common.masc_dir_from_base_path ~base_path) "lane-addons")

let load_attempt ~store =
  O.load_retained ~store ~verification_id ~attempt:0 ~installation_id ~package_id |> owner

(* Retains the original under [base_path] and records its dispatch intent. *)
let retain_original ~base_path =
  (* Original retention requires an existing owned parent as its authority
     anchor; the store creates only its own descendants. *)
  Unix.mkdir (Common.masc_dir_from_base_path ~base_path) 0o700;
  let store = store_of ~base_path in
  let original = make_original () in
  O.retain ~store ~verification_id ~attempt:0 ~installation_id ~package_id original |> retained;
  let current = ref (load_attempt ~store) in
  current := O.advance ~store !current P.Dispatch_intended |> owner;
  store,original,current

let with_fixture f = with_runtime (fun env sw ->
  let base_path = Filename.temp_dir "verifier-journal-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  let store,original,current = retain_original ~base_path in
  f env sw base_path store original current)

let reply calls =
  `Assoc ["id",`String "fixture-response";"model",`String model_id;
    "choices",`List [`Assoc ["index",`Int 0;"message",`Assoc
      (["role",`String "assistant";"content",`String "review finished"] @
        if calls=[] then [] else ["tool_calls",`List calls]);
      "finish_reason",`String (if calls=[] then "stop" else "tool_calls")]];
    "usage",`Assoc ["prompt_tokens",`Int 1;"completion_tokens",`Int 1;"total_tokens",`Int 2]]
  |> Yojson.Safe.to_string

let tool_call id input = `Assoc ["id",`String id;"type",`String "function";
  "function",`Assoc ["name",`String "report_review_verdict";
    "arguments",`String (Yojson.Safe.to_string input)]]
let valid = `Assoc ["verdict",`String "APPROVE";"reason",`String "checked exact evidence"]

(* Where a server shutdown interrupts the reviewer: while its provider request
   is open, before the report call of its first reply starts, while its report
   handler runs, on the provider request that follows a settled report, or
   before a report call of a later reply starts. *)
type cancel_point =
  | While_provider_answers
  | Before_report_starts
  | While_report_runs
  | After_report_settles
  | Before_later_report_starts

(* Where the reviewer's process ends, leaving its journal without a terminal:
   on its first provider request, inside its report handler, after the first
   of two reports one reply asked for has settled and before the second
   starts, or on the provider request that follows a settled report. *)
type process_end = Before_any_report | Inside_the_report | Between_two_reports | After_the_report
let lost_writer_exit = 87

(* The first provider reply carries [calls] and every later one [later_calls].
   [refuse_from]: the provider refuses the request with this ordinal and every
   later one. [block_report]: the pre-execution gate refuses every tool call. *)
let run_native ?(runtime_id=model_id) ?(refuse_publication=false) ?refuse_from ?(block_report=false)
    ?(later_calls=[]) ?process_end ?(on_result=fun _ -> ()) ?(after_scope_ready=fun () -> ()) ?cancel_at
    env sw ~base_path ~store ~original ~current calls =
  let provider_calls = ref 0 and handler_calls = ref 0 and gate_calls = ref 0 in
  let cancel_ready,cancel_now = Eio.Promise.create () in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
    ~on_request_before_reply:(fun () ->
      incr provider_calls;
      match process_end with
      | Some Before_any_report -> Unix._exit lost_writer_exit
      | Some After_the_report when !provider_calls > 1 -> Unix._exit lost_writer_exit
      | Some (Inside_the_report | Between_two_reports | After_the_report) | None -> ())
    (Exact_output_fixture.Reply_with (fun _ _ ->
      match cancel_at with
      | Some While_provider_answers -> Eio.Promise.resolve cancel_now ();Eio.Fiber.await_cancel ()
      | Some After_report_settles when !provider_calls > 1 ->
        Eio.Promise.resolve cancel_now ();Eio.Fiber.await_cancel ()
      | Some (Before_report_starts | While_report_runs | After_report_settles
             | Before_later_report_starts) | None ->
        (match refuse_from with
         | Some ordinal when !provider_calls >= ordinal ->
           `Bad_request, {|{"error":{"message":"refused by the fixture","type":"invalid_request_error"}}|}
         | Some _ | None -> `OK, reply (if !provider_calls=1 then calls else later_calls)))) in
  let provider_cfg = Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
    ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let state = ref AR.empty_verdict_call in
  let schema = Agent_core.Types.tool_schema_of_input_schema ~name:"report_review_verdict"
    ~description:"Report one completion verdict"
    ~input_schema:(`Assoc ["type",`String "object";"properties",`Assoc
      ["verdict",`Assoc ["type",`String "string"];"reason",`Assoc ["type",`String "string"]];
      "required",`List [`String "verdict";`String "reason"];"additionalProperties",`Bool false]) () |> get in
  let tool = Agent_core.Tool.of_schema schema (fun _ input ->
    incr handler_calls;
    (match process_end with
     | Some Inside_the_report -> Unix._exit lost_writer_exit
     | Some (Before_any_report | Between_two_reports | After_the_report) | None -> ());
    match cancel_at with
    | Some While_report_runs -> Eio.Promise.resolve cancel_now ();Eio.Fiber.await_cancel ()
    | Some (While_provider_answers | Before_report_starts | After_report_settles
           | Before_later_report_starts) | None ->
    let next,answer = AR.step_verdict_call !state input in
    state:=next;
    match answer with
    | AR.Verdict_recorded _ -> Ok {Agent_core.Types.content="recorded";content_blocks=None;_meta=None}
    | Verdict_refused {detail} | Verdict_already_recorded {detail} ->
      Error {Agent_core.Types.message=detail;recoverable=false;error_class=None}) in
  let config = Runtime_agent.default_config ~media_store:(Agent_core.History.Memory_store.create ()) ~name:(X.keeper_name original |> get)
    ~provider_cfg ~system_prompt:"Call the report tool." ~tools:[tool] in
  (* The gate runs after a call's invocation is recorded and before its
     attempt, so a cancellation here leaves a report call that never started. *)
  let gate _ =
    incr gate_calls;
    match cancel_at with
    | Some Before_report_starts ->
      Eio.Promise.resolve cancel_now ();Eio.Fiber.await_cancel ()
    | Some Before_later_report_starts when !gate_calls > 1 ->
      Eio.Promise.resolve cancel_now ();Eio.Fiber.await_cancel ()
    | Some (While_provider_answers | While_report_runs | After_report_settles | Before_later_report_starts) | None ->
      if block_report then Agent_core.Hooks.Block "the fixture gate refuses the report"
      else Agent_core.Hooks.Continue in
  (* The post hook runs once its call's result is settled, and the next call
     of the same reply has no invocation yet. *)
  let after_settlement _ =
    (match process_end with
     | Some Between_two_reports -> Unix._exit lost_writer_exit
     | Some (Before_any_report | Inside_the_report | After_the_report) | None -> ());
    Agent_core.Hooks.Continue in
  let config = {config with hooks=Some {Agent_core.Hooks.empty with
    pre_tool_use=Some gate;post_tool_use=Some after_settlement}} in
  let journal,config = Keeper_request_execution.prepare ~base_path:(X.session_root ~base_path original |> get)
    ~keeper_name:(X.keeper_name original |> get) ~config
    ~on_scope_ready:(fun ~call_id ->
      if refuse_publication then Error "injected ownership publication failure"
      else (
        let fact=X.capture ~original ~runtime_id ~execution:(Types_core.Native_execution {call_id}) |> get in
        current:=O.advance ~store !current (P.Execution_observed (Waiting fact)) |> owner;
        after_scope_ready ();
        Ok ())) () |> get in
  let run () = Eio.Switch.run (fun run_sw ->
    Runtime_agent.run_blocks ~sw:run_sw ~net:env#net ~config [Agent_core.Types.Text "Review"]) in
  let result = match cancel_at with
    | None -> Some (run ())
    | Some (While_provider_answers | Before_report_starts | While_report_runs | After_report_settles
           | Before_later_report_starts) ->
      Eio.Fiber.first (fun () -> Some (run ())) (fun () -> Eio.Promise.await cancel_ready;None) in
  on_result result;
  (* Discard the returned Agent result: only the original's durable references
     and a newly opened canonical journal are available to recovery. *)
  if refuse_publication then (match result with Some (Error _) -> ()
    | Some (Ok _) | None -> Alcotest.fail "unconfirmed ownership dispatched")
  else ignore result;
  ignore journal;
  !provider_calls,!handler_calls

let test_terminal_recovery_ignores_unavailable_producer () = with_fixture (fun env sw base_path store original current ->
  let first=run_native env sw ~base_path ~store ~original ~current [] in
  let second=run_native env sw ~base_path ~store ~original ~current [tool_call "verdict-1" valid] in
  Alcotest.(check (pair int int)) "first declared slot returned no verdict" (1,0) first;
  Alcotest.(check (pair int int)) "next slot settled one actual verdict" (2,1) second;
  let attempts = ref 0 in
  let recover () = W.run_attempt ~store ~verification_id ~attempt:0 ~installation_id ~package_id
    ~base_path ~prepare_authority:(fun () -> incr attempts;Error "producer VM is detached")
    ~prepare_notes:(fun _ -> "journal-backed recovered verdict") ~provider_rest:(fun _ -> AR.No_stated_rest) () in
  List.iter (fun () -> match recover () with
    | Ok (reviewed, {AR.verdict=Some (Approve "checked exact evidence");_}) ->
      Alcotest.(check bool) "recovery returns the original bound to this execution" true
        (Yojson.Safe.equal (V.to_json original) (V.to_json reviewed))
    | Ok _ | Error _ -> Alcotest.fail "exact original verdict did not recover") [();()];
  Alcotest.(check int) "recovery never prepares producer access or dispatches another model" 0 !attempts;
  match P.phase (O.progress (O.load_retained ~store ~verification_id ~attempt:0 ~installation_id ~package_id |> owner)) with
  | Judged _ -> () | _ -> Alcotest.fail "recovered verdict was not durably retained")

let test_owner_publication_precedes_provider () = with_fixture (fun env sw base_path store original current ->
  let counts=run_native ~refuse_publication:true env sw ~base_path ~store ~original ~current [tool_call "v" valid] in
  Alcotest.(check (pair int int)) "failed owner publication permits no provider or handler" (0,0) counts)

let test_invalid_report_is_not_a_verdict () = with_fixture (fun env sw base_path store original current ->
  let providers,handlers=run_native env sw ~base_path ~store ~original ~current
    [tool_call "invalid" (`Assoc ["reason",`String "missing verdict"])] in
  Alcotest.(check bool) "schema refusal was observed after a real provider response" true (providers>0);
  Alcotest.(check int) "schema rejection occurs before the handler" 0 handlers;
  match X.observe ~base_path ~original (O.progress !current) |> get with
  | Repair_required _ -> () | Awaiting | No_verdict _ | Verdict _ -> Alcotest.fail "invalid report became a judgment")

let test_historical_original_has_no_replay_authority () = with_fixture (fun _ _ base_path _ original current ->
  match X.observe ~base_path ~original (O.progress !current) |> get with
  | Repair_required _ -> () | Awaiting | No_verdict _ | Verdict _ -> Alcotest.fail "missing locator became recoverable")

let test_duplicate_report_cannot_recover () = with_fixture (fun env sw base_path store original current ->
  ignore (run_native env sw ~base_path ~store ~original ~current
    [tool_call "first" valid;tool_call "duplicate" valid]);
  match X.observe ~base_path ~original (O.progress !current) |> get with
  | Repair_required _ -> () | Awaiting | No_verdict _ | Verdict _ -> Alcotest.fail "duplicate report supplied a verdict")

let test_cancelled_reviewer_without_report_retries_as_a_successor () = with_fixture (fun env sw base_path store original current ->
  Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds (fun () ->
    ignore (run_native ~cancel_at:While_provider_answers env sw ~base_path ~store ~original ~current []));
  (match X.observe ~base_path ~original (O.progress !current) |> get with
   | No_verdict {first=runtime_id,Verifier_review_ending.Cancelled;later=[]} ->
     Alcotest.(check string) "the cancelled execution is named by its runtime" model_id runtime_id
   | No_verdict _ | Awaiting | Repair_required _ | Verdict _ ->
     Alcotest.fail "a settled cancellation without a report was not read as one ending without a verdict");
  let prepared = ref 0 in
  (match W.run_attempt ~store ~verification_id ~attempt:0 ~installation_id ~package_id
    ~base_path ~prepare_authority:(fun () -> incr prepared;Error "producer VM is detached")
    ~prepare_notes:(fun _ -> "unreachable") ~provider_rest:(fun _ -> AR.No_stated_rest) () with
   | Ok (_, {AR.verdict=None;retryable_runtimes;_}) ->
     Alcotest.(check (list string)) "the refusal names the cancelled runtime" [model_id] retryable_runtimes
   | Ok _ | Error _ -> Alcotest.fail "cancelled original did not become a retryable refusal");
  Alcotest.(check int) "recovery prepares no producer access" 0 !prepared;
  Alcotest.(check int) "the owner walk opens the next attempt" 1
    (O.next_attempt ~store ~verification_id ~installation_id ~package_id |> owner))

(* The reviewer's reply asks for its report and the review is cancelled before
   that call starts: the journal holds a requested report and no settled one. *)
let test_reviewer_cancelled_before_its_report_starts_is_reviewed_again () = with_fixture (fun env sw base_path store original current ->
  Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds (fun () ->
    Alcotest.(check (pair int int)) "the report was requested and its handler never ran" (1,0)
      (run_native ~cancel_at:Before_report_starts env sw ~base_path ~store ~original ~current
        [tool_call "unstarted-report" valid]));
  (match X.observe ~base_path ~original (O.progress !current) |> get with
   | No_verdict {first=runtime_id,Verifier_review_ending.Cancelled;later=[]} ->
     Alcotest.(check string) "the cancelled execution is named by its runtime" model_id runtime_id
   | No_verdict _ | Awaiting | Repair_required _ | Verdict _ ->
     Alcotest.fail "a requested report that never started was not read as an ending without a verdict");
  (match W.run_attempt ~store ~verification_id ~attempt:0 ~installation_id ~package_id
    ~base_path ~prepare_authority:(fun () -> Error "producer VM is detached")
    ~prepare_notes:(fun _ -> "unreachable") ~provider_rest:(fun _ -> AR.No_stated_rest) () with
   | Ok (_, {AR.verdict=None;retryable_runtimes;_}) ->
     Alcotest.(check (list string)) "the refusal names the cancelled runtime" [model_id] retryable_runtimes
   | Ok _ | Error _ -> Alcotest.fail "the cancelled original did not become a retryable refusal");
  Alcotest.(check int) "the owner walk opens the next attempt" 1
    (O.next_attempt ~store ~verification_id ~installation_id ~package_id |> owner))

let test_reviewer_cancelled_inside_its_report_stays_a_repair () = with_fixture (fun env sw base_path store original current ->
  Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds (fun () ->
    ignore (run_native ~cancel_at:While_report_runs env sw ~base_path ~store ~original ~current
      [tool_call "cancelled-report" valid]));
  match X.observe ~base_path ~original (O.progress !current) |> get with
  | Repair_required _ -> ()
  | Awaiting | No_verdict _ | Verdict _ ->
    Alcotest.fail "a cancellation inside the report handler authorized a retry or a verdict")

let test_reviewer_cancelled_after_its_report_keeps_the_verdict () = with_fixture (fun env sw base_path store original current ->
  Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds (fun () ->
    ignore (run_native ~cancel_at:After_report_settles env sw ~base_path ~store ~original ~current
      [tool_call "settled-report" valid]));
  match X.observe ~base_path ~original (O.progress !current) |> get with
  | Verdict {AR.verdict=Some (Approve reason);_} ->
    Alcotest.(check string) "the settled report is the verdict" "checked exact evidence" reason
  | Verdict _ | Awaiting | Repair_required _ | No_verdict _ ->
    Alcotest.fail "a cancellation after the settled report lost its verdict")

(* The provider refuses the request that follows a settled report, so the run
   ends as a failure. The handler had already recorded the verdict. *)
let test_reviewer_failing_after_its_report_keeps_the_verdict () = with_fixture (fun env sw base_path store original current ->
  let providers,handlers=run_native ~refuse_from:2 env sw ~base_path ~store ~original ~current
    ~on_result:(function
      | Some (Error _) -> ()
      | Some (Ok _) | None -> Alcotest.fail "the run did not end as a failure")
    [tool_call "settled-report" valid] in
  Alcotest.(check int) "the report handler ran once" 1 handlers;
  Alcotest.(check int) "the provider refused the request after the report" 2 providers;
  match X.observe ~base_path ~original (O.progress !current) |> get with
  | Verdict {AR.verdict=Some (Approve reason);_} ->
    Alcotest.(check string) "the settled report is the verdict" "checked exact evidence" reason
  | Verdict _ | Awaiting | Repair_required _ | No_verdict _ ->
    Alcotest.fail "a failure after the settled report lost its verdict")

(* The reviewer reports, and its next reply asks to report again. The review
   is cancelled before that second call starts, so the journal holds one
   settled report beside a report call that never ran. *)
let test_report_beside_one_that_never_started_is_not_a_verdict () = with_fixture (fun env sw base_path store original current ->
  Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds (fun () ->
    Alcotest.(check (pair int int)) "the second report was requested and its handler never ran" (2,1)
      (run_native ~cancel_at:Before_later_report_starts ~later_calls:[tool_call "second-report" valid]
        env sw ~base_path ~store ~original ~current [tool_call "first-report" valid]));
  match X.observe ~base_path ~original (O.progress !current) |> get with
  | Repair_required _ -> ()
  | Awaiting | No_verdict _ | Verdict _ ->
    Alcotest.fail "a report beside a second, never started report supplied a verdict or a retry")

let test_report_refused_by_the_gate_is_not_a_verdict () = with_fixture (fun env sw base_path store original current ->
  let providers,handlers=run_native ~block_report:true env sw ~base_path ~store ~original ~current
    [tool_call "refused-report" valid] in
  Alcotest.(check bool) "the provider asked for the report" true (providers>0);
  Alcotest.(check int) "the gate kept the report from its handler" 0 handlers;
  match X.observe ~base_path ~original (O.progress !current) |> get with
  | Repair_required _ -> ()
  | Awaiting | No_verdict _ | Verdict _ ->
    Alcotest.fail "a report the gate refused supplied a verdict or a retry")

let test_reports_from_two_executions_cannot_recover () = with_fixture (fun env sw base_path store original current ->
  List.iter (fun id ->
    Alcotest.(check (pair int int)) "each execution settled one report" (2,1)
      (run_native env sw ~base_path ~store ~original ~current [tool_call id valid])) ["first";"second"];
  match X.observe ~base_path ~original (O.progress !current) |> get with
  | Repair_required _ -> ()
  | Awaiting | No_verdict _ | Verdict _ ->
    Alcotest.fail "one report from each of two executions supplied a verdict or a retry")

let lost_writer_flag = "--reviewer-process-ends"
let process_ends = [Before_any_report;Inside_the_report;Between_two_reports;After_the_report]
let process_end_label = function
  | Before_any_report -> "before-any-report"
  | Inside_the_report -> "inside-the-report"
  | Between_two_reports -> "between-two-reports"
  | After_the_report -> "after-the-report"

(* Runs in a separate process: retains the original, starts its reviewer, and
   ends at [process_end]. *)
let lost_writer_child process_end base_path = with_runtime (fun env sw ->
  let store,original,current = retain_original ~base_path in
  let calls = match process_end with
    | Before_any_report -> []
    | Inside_the_report | After_the_report -> [tool_call "report" valid]
    | Between_two_reports -> [tool_call "first-report" valid;tool_call "second-report" valid] in
  ignore (run_native ~process_end env sw ~base_path ~store ~original ~current calls);
  (* Reached only when the fixture did not end the process. *)
  exit 1)

(* Starts a reviewer in another process, waits for that process to end at
   [process_end], and reads what its attempt retained. *)
let after_reviewer_process_ends process_end f = with_runtime (fun env sw ->
  let base_path = Filename.temp_dir "verifier-journal-lost-writer-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  (* Spawn rather than fork the multithreaded Eio runtime. *)
  let child = Eio.Process.spawn ~sw env#process_mgr
    [Sys.executable_name;lost_writer_flag;process_end_label process_end;base_path] in
  (match Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
      (fun () -> Eio.Process.await child) with
   | `Exited code -> Alcotest.(check int) "the reviewer process ended where the fixture ends it" lost_writer_exit code
   | `Signaled signal -> Alcotest.failf "the reviewer process died from signal %d" signal);
  let store = store_of ~base_path in
  let saved = load_attempt ~store in
  f ~base_path ~store (X.observe ~base_path ~original:(O.original saved) (O.progress saved) |> get))

let test_reviewer_process_ending_before_any_report_ends_without_a_verdict () =
  after_reviewer_process_ends Before_any_report (fun ~base_path:_ ~store:_ -> function
    | X.No_verdict {first=runtime_id,Verifier_review_ending.Owner_lost;later=[]} ->
      Alcotest.(check string) "the lost execution is named by its runtime" model_id runtime_id
    | No_verdict _ | Awaiting | Repair_required _ | Verdict _ ->
      Alcotest.fail "a journal whose writer is gone was not read as an ending without a verdict")

(* The attempt is recorded before the handler runs, so the journal shows a
   report whose outcome nobody knows. *)
let test_reviewer_process_ending_inside_its_report_stays_a_repair () =
  after_reviewer_process_ends Inside_the_report (fun ~base_path:_ ~store:_ -> function
    | X.Repair_required _ -> ()
    | Awaiting | No_verdict _ | Verdict _ ->
      Alcotest.fail "a report whose handler was running when its process ended authorized a retry or a verdict")

(* One reply asked for two reports. The first settled; the second has no
   invocation, because an invocation is opened only when its tool is about to
   run. The recorded reply still shows that the reviewer asked twice. *)
let test_reviewer_process_ending_between_two_reports_is_not_a_verdict () =
  after_reviewer_process_ends Between_two_reports (fun ~base_path:_ ~store:_ -> function
    | X.Repair_required _ -> ()
    | Awaiting | No_verdict _ | Verdict _ ->
      Alcotest.fail "the first of two requested reports supplied a verdict or a retry")

let test_reviewer_process_ending_after_its_report_keeps_the_verdict () =
  after_reviewer_process_ends After_the_report (fun ~base_path:_ ~store:_ -> function
    | X.Verdict {AR.verdict=Some (Approve reason);_} ->
      Alcotest.(check string) "the settled report is the verdict" "checked exact evidence" reason
    | Verdict _ | Awaiting | Repair_required _ | No_verdict _ ->
      Alcotest.fail "the end of the process after the settled report lost its verdict")

(* Reads the attempt's records the way a maintenance pulse does. The producer
   is detached, so a result can only come from what the attempt retained. *)
let reread ~base_path ~store =
  let prepared = ref 0 in
  let outcome = W.run_attempt ~store ~verification_id ~attempt:0 ~installation_id ~package_id
    ~base_path ~prepare_authority:(fun () -> incr prepared;Error "producer VM is detached")
    ~prepare_notes:(fun _ -> "unreachable") ~provider_rest:(fun _ -> AR.No_stated_rest) () in
  Alcotest.(check int) "rereading prepares no producer access" 0 !prepared;
  outcome

let next_attempt ~store = O.next_attempt ~store ~verification_id ~installation_id ~package_id |> owner

(* The provider refuses the only request, so the run ends as a failure and no
   report call exists. *)
let fail_without_report ?runtime_id env sw ~base_path ~store ~original ~current =
  Alcotest.(check (pair int int)) "the provider refused the only request and no report ran" (1,0)
    (run_native ?runtime_id ~refuse_from:1 env sw ~base_path ~store ~original ~current [])

(* The result a retained walk leaves once one candidate's outcome is unknown. *)
let unknown_outcome_result = {AR.verdict=None;evaluator_runtime=model_id;generator_runtime=None;
  evaluator_execution=None;gate=AR.Evaluator_unavailable;
  fallback_reason=Some "one reviewer's outcome is unknown";retryable_runtimes=[];model_absent_runtimes=[]}

(* [candidates]: runtime, certainty, error category and typed failure of each
   candidate the walk reported, in order. *)
let record_walk ?(result=unknown_outcome_result) ~store ~current candidates =
  current := O.advance ~store !current (P.Execution_observed (Outcome_unknown
    (Walk_result.to_json ~result:(O.result_to_json result)
      ~candidates:(List.map (fun (runtime_id,certainty,error_category,failure) ->
        {Walk_result.runtime_id;certainty;error_category;failure}) candidates)))) |> owner

let record_walk_result ~store ~current failure =
  record_walk ~store ~current [model_id,AR.Outcome_unknown,"api",failure]

let check_stays_a_repair label ~base_path ~store =
  (match reread ~base_path ~store with
   | Error (W.Execution_repair_required _) -> ()
   | Ok _ | Error _ -> Alcotest.fail label);
  (match P.phase (O.progress (load_attempt ~store)) with
   | Dispatch_pending _ -> ()
   | _ -> Alcotest.fail "the repair changed what the attempt retained");
  Alcotest.(check int) "the frontier stays on the pending attempt" 0 (next_attempt ~store)

let check_retryable label expected = function
  | Ok (_, {AR.verdict=None;gate=AR.Evaluator_unavailable;retryable_runtimes;_}) ->
    Alcotest.(check (list string)) label expected retryable_runtimes
  | Ok _ -> Alcotest.fail "rereading returned a verdict or another gate"
  | Error W.Original_not_found -> Alcotest.fail "rereading found no original"
  | Error (W.Original_corrupt detail | Authority_unavailable detail | Grants_mismatch detail
    | Execution_pending detail | Execution_repair_required detail | Persistence_unavailable detail) ->
    Alcotest.failf "rereading retained no refusal: %s" detail

let test_unknown_candidate_that_reviews_again_opens_the_next_attempt () = with_fixture (fun env sw base_path store original current ->
  fail_without_report env sw ~base_path ~store ~original ~current;
  record_walk_result ~store ~current AR.Reviews_again;
  reread ~base_path ~store |> check_retryable "the candidate that reviews again is named" [model_id];
  (match P.phase (O.progress (load_attempt ~store)) with
   | P.Rejected {P.stage=P.Execution;evidence=`Assoc fields} ->
     (match List.assoc_opt "observations" fields with
      | Some (`List [observation]) ->
        (match Verifier_review_ending.of_observation observation with
         | Some (runtime_id,Verifier_review_ending.Failed) ->
           Alcotest.(check string) "the refusal keeps the runtime of the ended execution" model_id runtime_id
         | Some (_,(Succeeded | Cancelled | Owner_lost)) | None ->
           Alcotest.fail "the refusal does not keep how the execution ended")
      | Some _ | None -> Alcotest.fail "the refusal does not hold one observation per execution")
   | _ -> Alcotest.fail "the attempt did not retain an execution refusal");
  Alcotest.(check int) "the owner walk opens the next attempt" 1 (next_attempt ~store))

let unknown_candidate_opens_no_attempt failure () = with_fixture (fun env sw base_path store original current ->
  fail_without_report env sw ~base_path ~store ~original ~current;
  record_walk_result ~store ~current failure;
  (* The second reading restores the retained refusal. *)
  List.iter (fun () ->
    reread ~base_path ~store |> check_retryable "no runtime is named for a retry" []) [();()];
  Alcotest.(check int) "the frontier stays on the refused attempt" 0 (next_attempt ~store))

let test_unknown_candidate_left_to_the_producer_opens_no_attempt =
  unknown_candidate_opens_no_attempt AR.Producer_must_act
let test_unknown_candidate_whose_model_is_absent_opens_no_attempt =
  unknown_candidate_opens_no_attempt AR.Model_absent

(* The shape a walk leaves when its first slot was refused for a time and its
   second ended unknown: both dispatched, so each has its own execution. The
   refusal then holds the first slot's definite refusal beside how each
   execution ended, and the owner walk reads it back. *)
let test_definite_refusal_before_the_unknown_candidate_is_reviewed_again () = with_fixture (fun env sw base_path store original current ->
  let first_slot = "first-slot-runtime" in
  fail_without_report ~runtime_id:first_slot env sw ~base_path ~store ~original ~current;
  fail_without_report env sw ~base_path ~store ~original ~current;
  record_walk ~store ~current
    [first_slot,AR.Definite_refusal,"rate_limit",AR.Reviews_again;
     model_id,AR.Outcome_unknown,"api",AR.Producer_must_act];
  reread ~base_path ~store |> check_retryable "only the slot that reviews again is named" [first_slot];
  (match P.phase (O.progress (load_attempt ~store)) with
   | P.Rejected {P.stage=P.Execution;evidence=`Assoc fields} ->
     (match List.assoc_opt "observations" fields with
      | Some (`List observations) ->
        Alcotest.(check int) "the definite refusal, then how each of the two executions ended" 3
          (List.length observations)
      | Some _ | None -> Alcotest.fail "the refusal holds no observations")
   | _ -> Alcotest.fail "the attempt did not retain an execution refusal");
  Alcotest.(check int) "the owner walk reads the refusal and opens the next attempt" 1 (next_attempt ~store))

(* A candidate refused before dispatch has no execution; its observation alone
   carries it into the refusal. *)
let test_candidate_refused_before_dispatch_is_reviewed_again () = with_fixture (fun env sw base_path store original current ->
  let never_dispatched = "never-dispatched-runtime" in
  fail_without_report env sw ~base_path ~store ~original ~current;
  record_walk ~store ~current
    [never_dispatched,AR.Before_dispatch,"capacity",AR.Reviews_again;
     model_id,AR.Outcome_unknown,"api",AR.Producer_must_act];
  reread ~base_path ~store |> check_retryable "the candidate refused before dispatch is named" [never_dispatched];
  Alcotest.(check int) "the owner walk reads the refusal and opens the next attempt" 1 (next_attempt ~store))

let test_unknown_candidate_without_an_execution_stays_a_repair () = with_fixture (fun env sw base_path store original current ->
  fail_without_report env sw ~base_path ~store ~original ~current;
  record_walk ~store ~current ["unrecorded-runtime",AR.Outcome_unknown,"api",AR.Reviews_again];
  check_stays_a_repair "an unknown candidate that left no execution chose a retry" ~base_path ~store)

let test_walk_result_that_already_names_a_retry_stays_a_repair () = with_fixture (fun env sw base_path store original current ->
  fail_without_report env sw ~base_path ~store ~original ~current;
  record_walk ~result:{unknown_outcome_result with AR.retryable_runtimes=[model_id]} ~store ~current
    [model_id,AR.Outcome_unknown,"api",AR.Reviews_again];
  check_stays_a_repair "a walk result an unknown outcome cannot leave chose a retry" ~base_path ~store)

let test_two_walk_results_stay_a_repair () = with_fixture (fun env sw base_path store original current ->
  fail_without_report env sw ~base_path ~store ~original ~current;
  record_walk_result ~store ~current AR.Reviews_again;
  record_walk_result ~store ~current AR.Producer_must_act;
  check_stays_a_repair "two walk results chose a retry" ~base_path ~store)

let test_cancellation_after_the_walk_result_does_not_hide_it () = with_fixture (fun env sw base_path store original current ->
  fail_without_report env sw ~base_path ~store ~original ~current;
  record_walk_result ~store ~current AR.Producer_must_act;
  current := O.advance ~store !current (P.Execution_observed (Outcome_unknown Walk_result.cancelled)) |> owner;
  reread ~base_path ~store |> check_retryable "the walk's typed failure still decides" [];
  Alcotest.(check int) "the frontier stays on the refused attempt" 0 (next_attempt ~store))

(* The observation a walk wrote before it retained each candidate's failure. *)
let test_unknown_outcome_without_candidate_failures_stays_a_repair () = with_fixture (fun env sw base_path store original current ->
  fail_without_report env sw ~base_path ~store ~original ~current;
  current := O.advance ~store !current (P.Execution_observed (Outcome_unknown
    (`Assoc ["schema",`String "verifier_review_unknown/v1";
      "result",O.result_to_json unknown_outcome_result]))) |> owner;
  check_stays_a_repair "an observation without candidate failures chose a retry" ~base_path ~store)

(* No walk result was retained: the walk was cut after the execution ended. *)
let test_cut_walk_whose_execution_failed_is_reviewed_again () = with_fixture (fun env sw base_path store original current ->
  fail_without_report env sw ~base_path ~store ~original ~current;
  reread ~base_path ~store |> check_retryable "the ended execution's runtime is named" [model_id];
  Alcotest.(check int) "the owner walk opens the next attempt" 1 (next_attempt ~store))

let test_cut_walk_whose_reviewer_replied_without_a_report_is_reviewed_again () = with_fixture (fun env sw base_path store original current ->
  Alcotest.(check (pair int int)) "the reviewer replied once and called no report" (1,0)
    (run_native env sw ~base_path ~store ~original ~current []);
  (match X.observe ~base_path ~original (O.progress !current) |> get with
   | No_verdict {first=_,Verifier_review_ending.Succeeded;later=[]} -> ()
   | No_verdict _ | Awaiting | Repair_required _ | Verdict _ ->
     Alcotest.fail "a reply without a report was not read as a success without a verdict");
  reread ~base_path ~store |> check_retryable "the ended execution's runtime is named" [model_id];
  Alcotest.(check int) "the owner walk opens the next attempt" 1 (next_attempt ~store))

let test_reviewer_process_ending_before_any_report_is_reviewed_again () =
  after_reviewer_process_ends Before_any_report (fun ~base_path ~store _ ->
    reread ~base_path ~store |> check_retryable "the lost execution's runtime is named" [model_id];
    Alcotest.(check int) "the owner walk opens the next attempt" 1 (next_attempt ~store))

let test_unreadable_execution_refusal_is_an_error () = with_fixture (fun _ _ _ store _ current ->
  current := O.advance ~store !current (P.Refused {P.stage=P.Execution;evidence=`Assoc [
    "schema",`String "verifier_review_refusal/v1";"certainty",`String "definite";
    "observations",`List [`Assoc ["fact",`String "ended_without_verdict";
      "runtime_id",`String model_id;"ending",`String "unheard-of"]];
    "result",O.result_to_json {unknown_outcome_result with AR.retryable_runtimes=[model_id]}]}) |> owner;
  match O.next_attempt ~store ~verification_id ~installation_id ~package_id with
  | Error (O.Corrupt_original _) -> ()
  | Ok _ | Error (O.Load_store_unavailable _ | O.Not_found) ->
    Alcotest.fail "a refusal that cannot be read chose a frontier")

let test_reference_bindings_are_strict () = with_fixture (fun _ _ base_path _ original current ->
  let fact=X.capture ~original ~runtime_id:model_id ~execution:(Types_core.Native_execution {call_id="fixture-call"}) |> get in
  let variants=match fact with
    | `Assoc fields ->
      [ `Assoc (("unexpected",`Bool true)::fields)
      ; `Assoc (("schema",`String "unknown")::List.remove_assoc "schema" fields)
      ; `Assoc (("original_digest",`String (String.make 64 '0'))::List.remove_assoc "original_digest" fields)
      ; `Assoc (("runtime_id",`String "other-runtime")::fields) ]
    | _ -> Alcotest.fail "capture must be an object" in
  List.iter (fun invalid ->
    match P.append (O.progress !current) (P.Execution_observed (Waiting invalid)) with
    | Error _ -> ()
    | Ok progress ->
      match X.observe ~base_path ~original progress with
      | Error _ -> () | Ok _ -> Alcotest.fail "invalid execution binding was accepted") variants)

let test_pending_cannot_change_its_physical_workspace () = with_fixture (fun _ _ base_path store _ _ ->
  let touched=ref false in
  match W.run_attempt ~store ~verification_id ~attempt:0 ~installation_id ~package_id
    ~base_path:(Filename.concat base_path "another-workspace")
    ~prepare_authority:(fun () -> touched:=true;Error "unavailable")
    ~prepare_notes:(fun _ -> "unreachable") ~provider_rest:(fun _ -> AR.No_stated_rest) () with
  | Error (W.Grants_mismatch _) -> Alcotest.(check bool) "foreign workspace is refused before lookup preparation" false !touched
  | Ok _ | Error _ -> Alcotest.fail "pending original accepted another physical workspace")

let test_earlier_open_call_prevents_later_verdict_recovery () = with_fixture (fun env sw base_path store original current ->
  Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds (fun () ->
    let ready,signal=Eio.Promise.create () in
    let release,unblock=Eio.Promise.create () in
    let finished,complete=Eio.Promise.create () in
    let released=ref false in
    let release_original () = if not !released then (
      released:=true;Eio.Promise.resolve unblock ()) in
    Eio.Fiber.fork ~sw (fun () ->
      ignore (run_native ~after_scope_ready:(fun () ->
        Eio.Promise.resolve signal ();Eio.Promise.await release)
        env sw ~base_path ~store ~original ~current []);
      Eio.Promise.resolve complete ());
    (* The scope-ready barrier may protect publication from cancellation.
       Always release the fixture's artificial wait before switch teardown. *)
    Fun.protect ~finally:release_original (fun () ->
      Eio.Promise.await ready;
      ignore (run_native env sw ~base_path ~store ~original ~current [tool_call "later" valid]);
      (match X.observe ~base_path ~original (O.progress !current) |> get with
       | Awaiting -> () | Repair_required _ | No_verdict _ | Verdict _ ->
         Alcotest.fail "later verdict bypassed the original still-open call");
      release_original ();Eio.Promise.await finished)))

let () =
  let prompts=Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts" in
  Prompt_registry.set_markdown_dir prompts;Prompt_registry.load_prompts_from_directory prompts;
  let child_end = match Array.to_list Sys.argv with
    | [_;flag;label;base_path] when String.equal flag lost_writer_flag ->
      List.find_opt (fun process_end -> String.equal (process_end_label process_end) label) process_ends
      |> Option.map (fun process_end -> process_end,base_path)
    | _ -> None in
  match child_end with
  | Some (process_end,base_path) -> lost_writer_child process_end base_path
  | None ->
  Alcotest.run "original verifier journals" ["recovery",[
    Alcotest.test_case "terminal original recovers with producer detached" `Quick test_terminal_recovery_ignores_unavailable_producer;
    Alcotest.test_case "owner publication is a pre-effect barrier" `Quick test_owner_publication_precedes_provider;
    Alcotest.test_case "schema-refused report is not a verdict" `Quick test_invalid_report_is_not_a_verdict;
    Alcotest.test_case "historical missing locator requires reconciliation" `Quick test_historical_original_has_no_replay_authority;
    Alcotest.test_case "duplicate report cannot supply a recovered verdict" `Quick test_duplicate_report_cannot_recover;
    Alcotest.test_case "cancelled reviewer without a report retries as a successor" `Quick test_cancelled_reviewer_without_report_retries_as_a_successor;
    Alcotest.test_case "reviewer cancelled before its report starts is reviewed again" `Quick test_reviewer_cancelled_before_its_report_starts_is_reviewed_again;
    Alcotest.test_case "reviewer cancelled inside its report stays a repair" `Quick test_reviewer_cancelled_inside_its_report_stays_a_repair;
    Alcotest.test_case "reviewer cancelled after its report keeps the verdict" `Quick test_reviewer_cancelled_after_its_report_keeps_the_verdict;
    Alcotest.test_case "reviewer failing after its report keeps the verdict" `Quick test_reviewer_failing_after_its_report_keeps_the_verdict;
    Alcotest.test_case "report beside one that never started is not a verdict" `Quick test_report_beside_one_that_never_started_is_not_a_verdict;
    Alcotest.test_case "report refused by the gate is not a verdict" `Quick test_report_refused_by_the_gate_is_not_a_verdict;
    Alcotest.test_case "reports from two executions cannot recover" `Quick test_reports_from_two_executions_cannot_recover;
    Alcotest.test_case "reviewer process ending before any report ends without a verdict" `Quick test_reviewer_process_ending_before_any_report_ends_without_a_verdict;
    Alcotest.test_case "reviewer process ending inside its report stays a repair" `Quick test_reviewer_process_ending_inside_its_report_stays_a_repair;
    Alcotest.test_case "reviewer process ending between two reports is not a verdict" `Quick test_reviewer_process_ending_between_two_reports_is_not_a_verdict;
    Alcotest.test_case "reviewer process ending after its report keeps the verdict" `Quick test_reviewer_process_ending_after_its_report_keeps_the_verdict;
    Alcotest.test_case "unknown candidate that reviews again opens the next attempt" `Quick test_unknown_candidate_that_reviews_again_opens_the_next_attempt;
    Alcotest.test_case "unknown candidate left to the producer opens no attempt" `Quick test_unknown_candidate_left_to_the_producer_opens_no_attempt;
    Alcotest.test_case "unknown candidate whose model is absent opens no attempt" `Quick test_unknown_candidate_whose_model_is_absent_opens_no_attempt;
    Alcotest.test_case "definite refusal before the unknown candidate is reviewed again" `Quick test_definite_refusal_before_the_unknown_candidate_is_reviewed_again;
    Alcotest.test_case "candidate refused before dispatch is reviewed again" `Quick test_candidate_refused_before_dispatch_is_reviewed_again;
    Alcotest.test_case "unknown candidate without an execution stays a repair" `Quick test_unknown_candidate_without_an_execution_stays_a_repair;
    Alcotest.test_case "walk result that already names a retry stays a repair" `Quick test_walk_result_that_already_names_a_retry_stays_a_repair;
    Alcotest.test_case "two walk results stay a repair" `Quick test_two_walk_results_stay_a_repair;
    Alcotest.test_case "cancellation after the walk result does not hide it" `Quick test_cancellation_after_the_walk_result_does_not_hide_it;
    Alcotest.test_case "unknown outcome without candidate failures stays a repair" `Quick test_unknown_outcome_without_candidate_failures_stays_a_repair;
    Alcotest.test_case "cut walk whose execution failed is reviewed again" `Quick test_cut_walk_whose_execution_failed_is_reviewed_again;
    Alcotest.test_case "cut walk whose reviewer replied without a report is reviewed again" `Quick test_cut_walk_whose_reviewer_replied_without_a_report_is_reviewed_again;
    Alcotest.test_case "reviewer process ending before any report is reviewed again" `Quick test_reviewer_process_ending_before_any_report_is_reviewed_again;
    Alcotest.test_case "unreadable execution refusal is an error" `Quick test_unreadable_execution_refusal_is_an_error;
    Alcotest.test_case "unknown and malformed execution bindings are refused" `Quick test_reference_bindings_are_strict;
    Alcotest.test_case "pending original cannot change physical workspace" `Quick test_pending_cannot_change_its_physical_workspace;
    Alcotest.test_case "earlier open call cannot be hidden by a later verdict" `Quick test_earlier_open_call_prevents_later_verdict_recovery]]
