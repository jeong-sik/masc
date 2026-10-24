open Masc
module AR = Task.Anti_rationalization
module A = Verification_authority_tools
module V = Goal_verifier_original
module W = Goal_verifier_worker
module P = Lane_addon_request_progress
let installation_id = "goal-review-fixture"
let package_id = "goal-proof-fixture"
let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let checked = function
  | Ok value -> value
  | Error (W.Store_unavailable detail | Original_invalid detail | Authority_changed detail | Execution_pending detail) ->
    Alcotest.fail detail
let stored = function Ok value -> value | Error e -> Alcotest.fail (Goal_store.write_error_to_string e)
let proof = function
  | Ok value -> value
  | Error (Workspace_goals.Store e) -> Alcotest.fail (Goal_store.write_error_to_string e)
  | Error (Workspace_goals.Refused {message; _}) -> Alcotest.fail message

let with_workspace f =
  let path = Filename.temp_dir "goal-worker-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.clear_fs (); Fs_compat.remove_tree path;
    Config_dir_resolver.reset ()) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key
    (Some (Filename.concat path ".masc/config")) (fun () ->
    Config_dir_resolver.reset ();
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Workspace.default_config path in
      ignore (Workspace.init config ~agent_name:(Some "planner"));
      let root = Filename.concat (Workspace_verification_store.project_root_of_base_path path)
        (Playground_paths.bundle_root "measurement-owner") in
      Fs_compat.mkdir_p root;
      Prompt_registry.set_markdown_dir (Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts");
      let store = Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
      f config store root))))

let measurement_path = "measurement-owner/measurement.json"
let measurement_reference = "artifact:" ^ measurement_path
let submit_measurement config goal_id value =
  let content = Printf.sprintf "{\"value\":%d}" value in
  let shared_root = Filename.concat
    (Workspace_verification_store.project_root_of_base_path config.Workspace.base_path)
    Playground_paths.all_playgrounds_prefix in
  Out_channel.with_open_bin (Filename.concat shared_root measurement_path)
    (fun out -> output_string out content);
  let item = Workspace_verification_store.Evidence_artifact {
    reference=measurement_reference; content; bytes=String.length content; truncated=false} in
  ignore (stored (Goal_store.transact_goal config ~goal_id (fun goal ->
    Result.map (fun record -> goal, record) (Goal_verification.mark_proof_pending
      ~submitted_evidence:[item] config ~goal_id ~criterion:(Goal_store.criterion_of_goal goal)))))

let pending config =
  let goal,_ = stored (Goal_store.upsert_goal config ~title:"Measure the original result"
    ~metric:measurement_reference ~target_value:"100" ()) in
  ignore (proof (Workspace_goals.request_current_proof config ~goal_id:goal.id));
  submit_measurement config goal.id 100;
  goal.id
let prepared config store =
  let goal_id = pending config in
  let authority = get (A.create_goal_review ~config ~goal_id) in
  let original = get (V.prepare ~attempt:0 ~authority) in
  let run : W.run_identity = {
    run_id="goal-review/" ^ (V.subject original).request_id;
    started_at=Time_compat.now ();
  } in
  let retained = checked (W.retain ~store ~installation_id ~package_id ~run original) in
  authority, retained
let load store original =
  let subject = V.subject original in
  match checked (W.load ~store ~installation_id ~package_id ~goal_id:subject.goal_id
    ~request_id:subject.request_id ~attempt:(V.attempt original)) with
  | Some value -> value | None -> Alcotest.fail "Goal original disappeared"
let run store retained authority =
  W.run ~store ~retained ~authority ~provider_rest:(fun _ -> AR.No_stated_rest) ()
let with_reviewer reviewer f =
  let old_reviewer = Atomic.get AR.run_llm_reviewer_fn in
  let old_slots = Atomic.get Workspace_hooks.get_verifier_exact_lane_slots_fn in
  Fun.protect ~finally:(fun () -> Atomic.set AR.run_llm_reviewer_fn old_reviewer;
    Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn old_slots) (fun () ->
    Atomic.set AR.run_llm_reviewer_fn reviewer;
    Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
      (fun () -> Ok ["goal-reviewer",Types_core.Catalog_slot]); f ())

let test_actual_retained_lookup_and_restored_receipt () = with_workspace (fun config store root ->
  let image = Filename.concat (Masc_test_deps.find_project_root ()) "test/fixtures/verifier-image-lookup.png" in
  let bytes = In_channel.with_open_bin image In_channel.input_all in
  Out_channel.with_open_bin (Filename.concat root "proof.png") (fun out -> output_string out bytes);
  let authority, retained = prepared config store in
  let original = W.original retained in
  let calls = ref 0 in
  with_reviewer (fun ~base_path ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
      ?system_prompt ?goal_blocks:_ ~report_tool_schema:_ ~lookup ~on_tool_result
      ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls;
    Alcotest.(check string) "actual original workspace" config.base_path base_path;
    Alcotest.(check string) "original Goal prompt" (V.prompt original) prompt;
    Alcotest.(check (option string)) "original system message" (Some (V.system_instructions original)) system_prompt;
    let input = `Assoc ["file_path", `String "measurement-owner/proof.png"] in
    let result = lookup.AR.dispatch ~name:"tool_read_file" ~args:input in
    (match result with
     | Tool_result.Completed {content_blocks=Some blocks; data; _} ->
       Alcotest.(check bool) "canonical full image reaches reviewer" true
         (List.exists (function Llm_provider.Types.Image {data; _} -> Base64.decode_exn data = bytes | _ -> false) blocks);
       Alcotest.(check bool) "shared successful-read projection" true
         (Yojson.Safe.Util.member "evidence_lookup_succeeded" data = `Bool true)
     | Tool_result.Completed {content_blocks=None; _} | Tool_result.Failed _ | Tool_result.Deferred _ ->
       Alcotest.fail (Tool_result.message result));
    on_tool_result ~input result;
    Ok {AR.selected_runtime_id="goal-reviewer"; verdict=Some (AR.Approve "The actual evidence reaches the metric.")})
    (fun () ->
      let first = checked (run store retained authority) in
      Alcotest.(check int) "exactly one actual reviewer entry" 1 !calls;
      Alcotest.(check bool) "actual read retained with result" true
        (List.exists (fun (tool:Verification_run_registry.tool_observation) -> tool.tool_name="tool_read_file") first.tools);
      let restored = load store original in
      let recovered = match checked (W.restored_receipt restored) with
        | Some receipt -> receipt | None -> Alcotest.fail "judgment not retained" in
      Alcotest.(check string) "the original observation run survives" first.run.run_id recovered.run.run_id;
      Alcotest.(check bool) "all original tool observations survive" true (first.tools = recovered.tools);
      let other_authority = get (A.create_goal_review ~config ~goal_id:(pending config)) in
      ignore (checked (run store restored other_authority));
      Alcotest.(check int) "restoring judgment never calls a model again" 1 !calls;
      match Goal_store.find_goal config ~goal_id:(V.subject original).goal_id with
      | Goal_store.Goal_found goal -> Alcotest.(check bool) "worker cannot apply Goal proof or confirmation" true
          (goal.phase = Goal_phase.Verifying)
      | Goal_absent | Store_unavailable _ -> Alcotest.fail "original Goal is absent"))

let test_unknown_and_cancellation_never_redispatch () =
  with_workspace (fun config store _ ->
    let authority, retained = prepared config store in
    let calls = ref 0 in
    with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
        ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
        ~attempt_continuation ~on_runtime_attempt_error () ->
      incr calls;
      let error = Agent_core.Error.Api (Agent_core.Error.Retry.NetworkError
        {message="Goal reply lost"; kind=Llm_provider.Http_client.Connection_reset}) in
      Alcotest.(check bool) "actual inner continuation must resolve its original" true
        (attempt_continuation ~dispatch:Runtime_attempt_dispatch.Dispatched error = Runtime_attempt_dispatch.Original_must_resolve);
      on_runtime_attempt_error ~runtime_id:"goal-reviewer" ~attempt:0 ~dispatch:Runtime_attempt_dispatch.Dispatched error;
      Error error) (fun () ->
      Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
        (fun () -> Ok ["goal-reviewer",Types_core.Catalog_slot;"must-not-run",Types_core.Catalog_slot]);
      let pending () = match run store retained authority with
        | Error (W.Execution_pending _) -> () | Ok _ | Error _ -> Alcotest.fail "unknown Goal original replayed" in
      pending (); pending ();
      let original = W.original retained in
      let subject = V.subject original in
      (match checked (W.frontier ~store ~installation_id ~package_id ~goal_id:subject.goal_id
          ~request_id:subject.request_id ~new_run:(fun () -> Alcotest.fail "unknown allocated a new run")) with
       | Some restored -> Alcotest.(check int) "unknown frontier retains the original attempt" 0
           (V.attempt (W.original restored))
       | None -> Alcotest.fail "unknown original disappeared from frontier");
      Alcotest.(check int) "no slot fallback or restart replay after unknown" 1 !calls));
  with_workspace (fun config store _ ->
    let authority, retained = prepared config store in
    let calls = ref 0 in
    with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
        ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
        ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls; raise (Eio.Cancel.Cancelled Exit)) (fun () ->
      (try ignore (run store retained authority); Alcotest.fail "Goal cancellation swallowed"
       with Eio.Cancel.Cancelled _ -> ());
      (match run store retained authority with
       | Error (W.Execution_pending _) -> () | Ok _ | Error _ -> Alcotest.fail "cancelled Goal original replayed");
      Alcotest.(check int) "cancelled reviewer called once" 1 !calls))

let test_pre_admission_repair_keeps_original () = with_workspace (fun config store _ ->
  let authority, retained = prepared config store in
  let calls = ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
      ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls; Ok {AR.selected_runtime_id="goal-reviewer"; verdict=Some (AR.Approve "admitted")}) (fun () ->
    Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn (fun () -> Error "fixture admission unavailable");
    let declined = checked (run store retained authority) in
    Alcotest.(check bool) "actual admission did not judge" true (declined.result.verdict = None);
    Alcotest.(check int) "no reviewer before admission repair" 0 !calls;
    let original = W.original retained in
    let restored = load store original in
    (match P.phase (W.progress restored) with
     | P.Admission_wait _ -> ()
     | Captured | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _ | Finished _
     | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> Alcotest.fail "preadmission became terminal execution");
    Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn (fun () -> Ok ["goal-reviewer",Types_core.Catalog_slot]);
    let result = checked (run store restored authority) in
    Alcotest.(check int) "one actual provider entry after repair" 1 !calls;
    Alcotest.(check string) "same original run after repair" (W.run_identity retained).run_id result.run.run_id;
    Alcotest.(check int) "same attempt after repair" 0 (V.attempt (W.original (load store original)))))

let test_destination_authority_and_inventory () = with_workspace (fun config store _ ->
  let authority, retained = prepared config store in
  let other_authority = get (A.create_goal_review ~config ~goal_id:(pending config)) in
  let calls = ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
      ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls; Alcotest.fail "unauthorized Goal review dispatched") (fun () ->
    (match run store retained other_authority with
     | Error (W.Authority_changed _) -> () | Ok _ | Error _ -> Alcotest.fail "other Goal authority admitted");
    let original = W.original retained in
    let subject = V.subject original in
    (match W.load ~store ~installation_id ~package_id:"other-package" ~goal_id:subject.goal_id
        ~request_id:subject.request_id ~attempt:0 with
     | Error (W.Authority_changed _) -> () | Ok _ | Error _ -> Alcotest.fail "another destination admitted");
    let changed_run = {(W.run_identity retained) with run_id="different-run"} in
    (match W.retain ~store ~installation_id ~package_id ~run:changed_run original with
     | Error _ -> () | Ok _ -> Alcotest.fail "wake replaced original run identity");
    let rows = checked (W.inventory ~store ~installation_id ~package_id) in
    Alcotest.(check bool) "strict discovery finds the original subject" true
      (List.exists (fun row -> (V.subject (W.original row)).request_id=subject.request_id) rows);
    get (Lane_addon_tool_request_owner.retain ~store ~scope:"goal-proof-reviews" ~request_id:"malformed"
      ~installation_id ~package_id ~tool:"goal_proof_review" ~summary:(`Assoc []) ~request:(`Assoc [])
      |> Result.map_error Lane_addon_tool_request_owner.error_to_string);
    (match W.inventory ~store ~installation_id ~package_id with
     | Error (W.Original_invalid _) -> () | Ok _ | Error _ -> Alcotest.fail "partial corrupt inventory admitted");
    Alcotest.(check int) "no refused path calls model" 0 !calls;
    ignore authority))

let test_linked_frontier_and_staged_run_recovery () =
  let exercise crash_before_child = with_workspace (fun config store _ ->
    let authority, retained = prepared config store in
    let original = W.original retained in
    let subject = V.subject original in
    let calls = ref 0 in
    with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
        ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
        ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls;
      Alcotest.(check string) "retry keeps complete original prompt" (V.prompt original) prompt;
      if !calls = 1 then Error (Agent_core.Error.Api (Agent_core.Error.Retry.RateLimited
        {retry_after=Some 1.; message="definite temporary refusal"}))
      else Ok {AR.selected_runtime_id="goal-reviewer"; verdict=Some (AR.Approve "checked original")}) (fun () ->
      let refusal = checked (run store retained authority) in
      Alcotest.(check bool) "typed definite refusal retains retry candidate" true
        (refusal.result.retryable_runtimes <> []);
      let allocations = ref 0 in
      let fixed_run : W.run_identity = {run_id="fixed-successor/" ^ subject.request_id;
        started_at=Time_compat.now ()} in
      if crash_before_child then (
        (* Publish a real staged body and parent intent, then stop before child
           publication. A separate actual store supplies the same opaque
           request bytes as normal retain; no private owner record is forged. *)
        let staged_store = Lane_addon_store.create
          ~root:(Filename.concat (Workspace.masc_dir config) "staged-goal-fixture") in
        let child = get (V.successor original) in
        ignore (checked (W.retain ~store:staged_store ~installation_id ~package_id ~run:fixed_run child));
        let load_scope store = get (Lane_addon_tool_request_owner.load_scope ~store
            ~scope:"goal-proof-reviews" |> Result.map_error Lane_addon_tool_request_owner.error_to_string) in
        let only = function [record] -> record | _ -> Alcotest.fail "fixture needs one actual owner" in
        let child_record = only (load_scope staged_store) in
        let parent_record = only (load_scope store) in
        let successor = get (Lane_addon_tool_request_owner.prepare_successor ~store
          ~scope:"goal-proof-reviews" ~request_id:child_record.request_id ~request:child_record.request
          |> Result.map_error Lane_addon_tool_request_owner.error_to_string) in
        ignore (get (Lane_addon_tool_request_owner.advance ~store ~expected:parent_record
          ~event:(P.Successor_intended successor)
          |> Result.map_error Lane_addon_tool_request_owner.update_error_to_string)));
      let next () = match checked (W.frontier ~store ~installation_id ~package_id
          ~goal_id:subject.goal_id ~request_id:subject.request_id ~new_run:(fun () ->
            if crash_before_child then Alcotest.fail "restart invented another child run";
            incr allocations; fixed_run)) with
        | Some child -> child | None -> Alcotest.fail "retained frontier disappeared" in
      let child = next () in
      Alcotest.(check int) "one linked successor" 1 (V.attempt (W.original child));
      Alcotest.(check string) "fixed staged run survives" fixed_run.run_id (W.run_identity child).run_id;
      ignore (next ());
      Alcotest.(check int) "no run allocation during restart" (if crash_before_child then 0 else 1) !allocations;
      ignore (checked (run store child authority));
      Alcotest.(check int) "only definite terminal failure gets a new provider attempt" 2 !calls;
      ignore (next ());
      Alcotest.(check int) "judged frontier does not create another successor" 2 !calls)) in
  exercise false;
  exercise true

let test_actual_goal_commit_reply_loss_and_conflict () =
  let exercise conflict = with_workspace (fun config store _ ->
    let authority, retained = prepared config store in
    let original = W.original retained in
    let subject = V.subject original in
    let calls = ref 0 in
    with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
        ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
        ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls; Ok {AR.selected_runtime_id="goal-reviewer"; verdict=Some (AR.Approve "actual proof")}) (fun () ->
      let receipt = checked (run store retained authority) in
      let retained = load store original in
      let judgment = checked (W.retained_judgment retained) in
      let read () = match get (Goal_verification.get_record_authoritative config ~goal_id:subject.goal_id) with
        | Some record -> record | None -> Alcotest.fail "actual Goal proof vanished" in
      let before = Goal_verification.record_to_yojson (read ()) in
      let after = `Assoc ["schema", `String "goal_proof_commit/v1";
        "original_digest", `String (get (V.digest original)); "receipt", judgment] in
      let applications = ref 0 in
      let observe (_:P.change) =
        let record = read () in
        match record.Goal_verification.completion with
        | Proof_proven verdict when verdict.request_id = subject.request_id
            && verdict.verification_run_id = receipt.run.run_id
            && Goal_store.criterion_equal verdict.criterion subject.criterion
            && verdict.authority = Workspace_goals.verifier_authority
            && verdict.evidence = "actual proof" ->
          (match Goal_store.find_goal config ~goal_id:subject.goal_id with
           | Goal_found goal when goal.phase = Goal_phase.Awaiting_confirmation -> Ok after
           | Goal_found _ | Goal_absent | Store_unavailable _ -> Error "Goal phase not confirmed")
        | Completion_idle | Proof_pending _ | Proof_proven _ | Proof_refuted _ | Human_confirmed _ ->
          Ok (Goal_verification.record_to_yojson record) in
      let apply (_:P.change) =
        incr applications;
        let result = Workspace_goals.commit_verifier_decision
          ~before_proof_commit:(Candle_snapshot.before_proof_commit config)
          ~tool_name:"goal_fixture_commit" ~start_time:(Tool_timing.start ()) config
          ~goal_id:subject.goal_id ~verification_run_id:receipt.run.run_id
          ~request_id:subject.request_id ~criterion:subject.criterion
          ~decision:Workspace_goals.Proof_proven ~evidence:"actual proof" in
        if Tool_result.is_success result then Error "actual proof committed but reply lost"
        else Error (Tool_result.message result) in
      if conflict then submit_measurement config subject.goal_id 101;
      (match W.commit ~store ~retained ~change:{P.before; after} ~observe ~apply with
       | Error (W.Execution_pending _) -> () | Ok _ | Error _ -> Alcotest.fail "commit frontier was not retained");
      let restored = load store original in
      if conflict then (
        Alcotest.(check int) "another request cannot authorize old proof" 0 !applications;
        match P.phase (W.progress restored) with
        | Conflicted _ -> ()
        | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
        | Finished _ | Rejected _ | Subdividing _ | Subdivided _ -> Alcotest.fail "conflict was not retained")
      else (
        checked (W.commit ~store ~retained:restored ~change:{P.before=`Null;after=`Null} ~observe ~apply);
        ignore (checked (run store restored authority));
        Alcotest.(check int) "exact committed state prevents duplicate proof/Candle effects" 1 !applications;
        Alcotest.(check int) "commit recovery never calls another model" 1 !calls;
        match P.phase (W.progress (load store original)) with
        | Finished _ -> ()
        | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
        | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> Alcotest.fail "commit was not confirmed"))) in
  exercise false;
  exercise true

module H = Goal_verifier_host
module R = Goal_verification_run_registry
module Agent = Goal_verification_agent.For_testing
let hosted = function Ok value -> value | Error error -> Alcotest.fail (H.error_to_string error)
let host_prepared config store =
  let goal_id = pending config in
  let authority = get (A.create_goal_review ~config ~goal_id) in
  let original = get (V.prepare ~attempt:0 ~authority) in
  let run : W.run_identity = {run_id="host/" ^ (V.subject original).request_id; started_at=Time_compat.now ()} in
  authority, checked (W.retain ~store ~installation_id:W.host_installation_id
    ~package_id:W.host_package_id ~run original)
let host_load store original =
  let subject = V.subject original in
  match checked (W.load ~store ~installation_id:W.host_installation_id ~package_id:W.host_package_id
    ~goal_id:subject.goal_id ~request_id:subject.request_id ~attempt:(V.attempt original)) with
  | Some retained -> retained | None -> Alcotest.fail "actual host original vanished"
let drain config = match Agent.drain_once config with
  | Ok () -> () | Error error -> Alcotest.fail (Agent.scan_failure_to_string error)
let phase config goal_id = match Goal_store.find_goal config ~goal_id with
  | Goal_found goal -> goal.phase
  | Goal_absent -> Alcotest.fail "Goal vanished"
  | Store_unavailable unavailable -> Alcotest.fail (Goal_store.unavailable_to_string unavailable)
let transition config goal_id action =
  let ctx : Workspace_types.context = {config; agent_name="planner"} in
  let result = Workspace_goals.handle_goal_transition ~tool_name:"goal_transition"
    ~start_time:(Tool_timing.start ()) ctx
    (`Assoc ["goal_id", `String goal_id; "action", `String action; "note", `String "fixture actor request"]) in
  if not (Tool_result.is_success result) then Alcotest.fail (Tool_result.message result)
let actual_review verdict calls =
  fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup ~on_tool_result
      ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls;
    let input = `Assoc ["file_path", `String measurement_path] in
    let result = lookup.AR.dispatch ~name:"tool_read_file" ~args:input in
    if not (Tool_result.is_success result) then Alcotest.fail (Tool_result.message result);
    on_tool_result ~input result;
    Ok {AR.selected_runtime_id="goal-reviewer"; verdict=Some verdict}
let actual_approve calls = actual_review (AR.Approve "actual target measured") calls

let test_actual_agent_restores_before_lookup_and_registry () = with_workspace (fun config store root ->
  let authority, retained = host_prepared config store in
  let original = W.original retained in
  let subject = V.subject original in
  let calls = ref 0 in
  with_reviewer (actual_approve calls) (fun () ->
    let first = checked (run store retained authority) in
    Alcotest.(check bool) "actual tool result exists before restart" true (first.tools <> []);
    Alcotest.(check bool) "registry is actually missing" true
      (R.get (R.global ()) ~run_id:first.run.run_id = None);
    let shared_root = Filename.dirname root in
    Fs_compat.remove_tree shared_root;
    Out_channel.with_open_bin shared_root (fun out -> output_string out "not a lookup directory");
    (match A.create_goal_review ~config ~goal_id:subject.goal_id with
     | Error _ -> () | Ok _ -> Alcotest.fail "lookup refusal fixture did not really fail");
    let prompt_dir = Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts" in
    Fun.protect ~finally:(fun () -> Prompt_registry.set_markdown_dir prompt_dir) (fun () ->
      Prompt_registry.set_markdown_dir (Filename.concat config.base_path "missing-prompts");
      drain config;
      drain config);
    Alcotest.(check int) "production recovery never asks another model" 1 !calls;
    Alcotest.(check bool) "human confirmation still pending" true
      (phase config subject.goal_id = Goal_phase.Awaiting_confirmation);
    (match R.get (R.global ()) ~run_id:first.run.run_id with
     | Some (R.Review {status=R.Completed {outcome=R.Committed; tools; _}; started_at; _}) ->
       Alcotest.(check bool) "same original tools and start time survive" true
         (tools = first.tools && started_at = first.run.started_at)
     | None | Some (R.Review _ | R.Scan_skipped _) -> Alcotest.fail "actual fixed run completion was not restored");
    match P.phase (W.progress (host_load store original)) with
    | Finished _ -> ()
    | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
    | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> Alcotest.fail "actual host did not confirm its original commit"))

let test_actual_partial_proof_and_nonverifying_boot () =
  let exercise rejected suspension = with_workspace (fun config store _ ->
    let authority, retained = host_prepared config store in
    let original = W.original retained in
    let subject = V.subject original in
    let calls = ref 0 in
    let reason = "actual target measured" in
    let decision = if rejected then AR.Reject reason else AR.Approve reason in
    let outcome = if rejected then Goal_verification.Refuted {reason} else Goal_verification.Proven in
    with_reviewer (actual_review decision calls) (fun () ->
      let receipt = checked (run store retained authority) in
      let verdict : Goal_verification.verdict = {outcome;
        request_id=subject.request_id; criterion=subject.criterion; verification_run_id=receipt.run.run_id;
        authority=Workspace_goals.verifier_authority; evidence=reason; recorded_at=Masc_domain.now_iso ()} in
      ignore (stored (Goal_store.transact_goal config ~goal_id:subject.goal_id (fun goal ->
        Result.map (fun record -> goal, record) (Goal_verification.record_proof_verdict
          ~before_commit:(fun () -> Candle_snapshot.before_proof_commit config goal verdict)
          config ~goal_id:subject.goal_id verdict))));
      Alcotest.(check bool) "real ledger-before-phase crash" true (phase config subject.goal_id=Goal_phase.Verifying);
      (match suspension with
       | None -> hosted (H.commit_proof ~config ~store ~registry:(R.global ()) (host_load store original))
       | Some action ->
         ignore (stored (Workspace_goals.reconcile_committed_proof config ~goal_id:subject.goal_id));
         transition config subject.goal_id (match action with `Pause -> "pause" | `Block -> "block"));
      (* In the suspended cases no Host call or final owner ACK happened: the
         actual scan must find Judged even outside Verifying, without a model. *)
      drain config;
      Alcotest.(check int) "phase-moved boot recovery makes no model call" 1 !calls;
      let expected_phase = match suspension, rejected with
        | None, false -> Goal_phase.Awaiting_confirmation
        | None, true -> Goal_phase.Executing
        | Some `Pause, false -> Goal_phase.Paused Resume_awaiting_confirmation
        | Some `Pause, true -> Goal_phase.Paused Resume_executing
        | Some `Block, false -> Goal_phase.Blocked Resume_awaiting_confirmation
        | Some `Block, true -> Goal_phase.Blocked Resume_executing in
      Alcotest.(check bool) "post-commit operator suspension remains intact" true
        (phase config subject.goal_id=expected_phase);
      (match R.get (R.global ()) ~run_id:receipt.run.run_id with
       | Some (R.Review {status=R.Completed {outcome=R.Committed; _}; _}) -> ()
       | None | Some (R.Review _ | R.Scan_skipped _) -> Alcotest.fail "phase-moved original missing from actual boot recovery");
      match get (Goal_verification.get_record_authoritative config ~goal_id:subject.goal_id) with
      | Some {completion=(Goal_verification.Proof_proven stored | Proof_refuted stored); _} ->
        Alcotest.(check string) "original proof timestamp was not rewritten" verdict.recorded_at stored.recorded_at
      | None | Some _ -> Alcotest.fail "real proof was lost")) in
  exercise false None;
  exercise true None;
  List.iter (fun action -> exercise false (Some action); exercise true (Some action)) [`Pause; `Block]

let test_cloned_workspace_cannot_commit_original () = with_workspace (fun config store _ ->
  let authority, retained = host_prepared config store in
  let original = W.original retained in
  let subject = V.subject original in
  let calls = ref 0 in
  with_reviewer (actual_approve calls) (fun () ->
    ignore (checked (run store retained authority));
    let other = Workspace.default_config (Filename.concat config.base_path "cloned-workspace") in
    let copy source target =
      Fs_compat.mkdir_p (Filename.dirname target);
      let bytes = In_channel.with_open_bin source In_channel.input_all in
      Out_channel.with_open_bin target (fun out -> output_string out bytes) in
    copy (Goal_store.goals_path config) (Goal_store.goals_path other);
    copy (Goal_verification.verifications_path config) (Goal_verification.verifications_path other);
    (match get (Goal_verification.get_record_authoritative other ~goal_id:subject.goal_id) with
     | Some {completion=Goal_verification.Proof_pending pending; _} ->
       Alcotest.(check string) "actual cloned request ID is identical" subject.request_id pending.request_id
     | None | Some _ -> Alcotest.fail "cloned primary proof was not readable");
    (match H.commit_proof ~config:other ~store ~registry:(R.global ()) (host_load store original) with
     | Error (H.Conflict _) -> () | Ok () | Error _ -> Alcotest.fail "another workspace accepted the retained proof");
    Alcotest.(check bool) "neither original nor clone changed phase" true
      (phase config subject.goal_id=Goal_phase.Verifying && phase other subject.goal_id=Goal_phase.Verifying)))

let test_actual_explicit_retry_and_unknown_fence () =
  let exercise unknown = with_workspace (fun config store _ ->
    let authority, retained = host_prepared config store in
    let original = W.original retained in
    let subject = V.subject original in
    let calls = ref 0 in
    with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
        ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
        ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls;
      if unknown then Error (Agent_core.Error.Api (Agent_core.Retry.NetworkError
        {message="reply lost"; kind=Llm_provider.Http_client.Connection_reset}))
      else Error (Agent_core.Error.Api (Agent_core.Retry.NotFound {message="candidate removed"}))) (fun () ->
      ignore (run store retained authority);
      transition config subject.goal_id "request_complete";
      let rows = checked (W.inventory ~store ~installation_id:W.host_installation_id ~package_id:W.host_package_id) in
      Alcotest.(check int) "explicit request links only a definitely settled failure" (if unknown then 1 else 2) (List.length rows);
      Atomic.set AR.run_llm_reviewer_fn (actual_approve calls);
      drain config;
      Alcotest.(check int) "unknown execution never re-enters after explicit request" (if unknown then 1 else 2) !calls;
      Alcotest.(check bool) "actual phase follows definite retry authority" true
        (phase config subject.goal_id = if unknown then Goal_phase.Verifying else Awaiting_confirmation))) in
  exercise false;
  exercise true

let test_reasonless_goal_reply_requires_explicit_retry () =
  let exercise reason = with_workspace (fun config store _ ->
    let _, retained = host_prepared config store in
    let original = W.original retained in
    let subject = V.subject original in
    let calls = ref 0 in
    with_reviewer (actual_review (AR.Approve reason) calls) (fun () ->
      drain config;
      let store = Lane_addon_store.create ~root:(Lane_addon_store.root store) in
      let config = Workspace.default_config config.base_path in
      let restored = host_load store original in
      (match P.phase (W.progress restored) with
       | Rejected {stage=P.Execution; _} -> ()
       | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
       | Commit_unknown _ | Finished _ | Conflicted _ | Rejected {stage=P.Before_dispatch; _}
       | Subdividing _ | Subdivided _ -> Alcotest.fail "reasonless Goal reply became a judgment");
      let receipt = match checked (W.restored_receipt restored) with
        | Some receipt -> receipt | None -> Alcotest.fail "original reply was not retained" in
      Alcotest.(check bool) "raw model verdict and actual lookup survive reopening" true
        (receipt.result.verdict = Some (AR.Approve reason) && receipt.tools <> []);
      Atomic.set AR.run_llm_reviewer_fn (actual_approve calls);
      (match Agent.process_pending_work config {Agent.goal_id=subject.goal_id} with
       | Deferred Verdict_without_reason -> ()
       | Deferred _ | Committed | Superseded -> Alcotest.fail "ordinary wake lost the original non-judgment");
      Alcotest.(check int) "ordinary wake does not redispatch" 1 !calls;
      Alcotest.(check bool) "ordinary wake leaves proof pending" true
        (phase config subject.goal_id=Goal_phase.Verifying);
      transition config subject.goal_id "request_complete";
      transition config subject.goal_id "request_complete";
      let rows = checked (W.inventory ~store ~installation_id:W.host_installation_id
        ~package_id:W.host_package_id) in
      Alcotest.(check int) "repeated explicit request retains one linked successor" 2 (List.length rows);
      drain config;
      Alcotest.(check int) "explicit request makes one new model call" 2 !calls;
      Alcotest.(check bool) "stated evidence advances to human confirmation" true
        (phase config subject.goal_id=Goal_phase.Awaiting_confirmation);
      match get (Goal_verification.get_record_authoritative config ~goal_id:subject.goal_id) with
      | Some {completion=Goal_verification.Proof_proven verdict; _} ->
        Alcotest.(check string) "proof binds the original pending request" subject.request_id verdict.request_id;
        Alcotest.(check string) "proof uses the new stated evidence" "actual target measured" verdict.evidence;
        Alcotest.(check bool) "successor has its own fixed run" true
          (verdict.verification_run_id <> receipt.run.run_id)
      | None | Some _ -> Alcotest.fail "explicit retry did not commit the actual Goal proof")) in
  List.iter exercise [""; " \t\n"]

let test_actual_bound_suspend_and_drop () =
  let exercise dropped = with_workspace (fun config store _ ->
    let authority, retained = host_prepared config store in
    let original = W.original retained in
    let subject = V.subject original in
    let calls = ref 0 in
    with_reviewer (actual_approve calls) (fun () ->
      ignore (checked (run store retained authority));
      transition config subject.goal_id (if dropped then "drop" else "pause");
      drain config;
      Alcotest.(check int) "suspended or dropped original never calls another model" 1 !calls;
      Alcotest.(check bool) "actual operator lifecycle is preserved" true
        (phase config subject.goal_id = if dropped then Goal_phase.Dropped else Paused Resume_verifying);
      if not dropped then (
        transition config subject.goal_id "resume";
        Alcotest.(check bool) "resume reconciles proof without human completion" true
          (phase config subject.goal_id=Goal_phase.Awaiting_confirmation)))) in
  exercise false;
  exercise true

let () = Alcotest.run "retained Goal worker" ["execution", [
  Alcotest.test_case "actual retained visual lookup and restart receipt" `Quick test_actual_retained_lookup_and_restored_receipt;
  Alcotest.test_case "unknown and cancellation never redispatch" `Quick test_unknown_and_cancellation_never_redispatch;
  Alcotest.test_case "same-original pre-admission repair" `Quick test_pre_admission_repair_keeps_original;
  Alcotest.test_case "authority destination and strict inventory" `Quick test_destination_authority_and_inventory;
  Alcotest.test_case "linked frontier restores the original staged run" `Quick test_linked_frontier_and_staged_run_recovery;
  Alcotest.test_case "actual Goal proof commit reply loss and conflict" `Quick test_actual_goal_commit_reply_loss_and_conflict;
  Alcotest.test_case "actual agent restores before lookup and registry" `Quick test_actual_agent_restores_before_lookup_and_registry;
  Alcotest.test_case "actual proof partial write and phase-moved boot" `Quick test_actual_partial_proof_and_nonverifying_boot;
  Alcotest.test_case "actual explicit retry and unknown fence" `Quick test_actual_explicit_retry_and_unknown_fence;
  Alcotest.test_case "reasonless Goal reply needs an explicit linked retry" `Quick test_reasonless_goal_reply_requires_explicit_retry;
  Alcotest.test_case "actual bound suspend and drop" `Quick test_actual_bound_suspend_and_drop;
  Alcotest.test_case "cloned workspace refuses the original judgment" `Quick test_cloned_workspace_cannot_commit_original]]
