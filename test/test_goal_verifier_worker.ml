open Masc

type restart_probe = {base_path : string; goal_id : string; request_id : string; attempt : int}
let restart_argument = "--recover-goal-body-fixture"
let restart_probe =
  if Array.length Sys.argv > 1 && Sys.argv.(1) = restart_argument then (
    if Array.length Sys.argv <> 6 then invalid_arg "Goal restart probe requires base, Goal, request and attempt";
    Some {base_path=Sys.argv.(2); goal_id=Sys.argv.(3); request_id=Sys.argv.(4);
      attempt=int_of_string Sys.argv.(5)})
  else None

(* Exercise host publication against an actual replayed durable registry.
   The restart child uses the workspace's real registry path; normal Alcotest
   cases retain their process-wide private registry. *)
let () =
  let directory = match restart_probe with
    | Some probe -> Common.masc_dir_from_base_path ~base_path:probe.base_path
    | None ->
      let directory = Filename.temp_dir "goal-review-registry-" "" in
      at_exit (fun () -> Fs_compat.clear_fs (); Fs_compat.remove_tree directory);
      directory in
  let registry = Goal_verification_run_registry.replay
    (Filename.concat directory Goal_verification_run_registry.storage_filename) in
  match Goal_verification_run_registry.install_global registry with
  | Ok () -> ()
  | Error Already_installed -> Alcotest.fail "Goal review fixture registry already installed"

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

let with_workspace_directory f =
  let path = Filename.temp_dir "goal-worker-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.clear_fs (); Fs_compat.remove_tree path;
    Config_dir_resolver.reset ()) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key
    (Some (Filename.concat path ".masc/config")) (fun () ->
    Config_dir_resolver.reset ();
    f path)))

let with_workspace_context ~initialize path f =
  Fun.protect ~finally:Fs_compat.clear_fs (fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Workspace.default_config path in
      if initialize then ignore (Workspace.init config ~agent_name:(Some "planner"));
      let root = Filename.concat (Workspace_verification_store.project_root_of_base_path path)
        (Playground_paths.bundle_root "measurement-owner") in
      if initialize then Fs_compat.mkdir_p root;
      Prompt_registry.set_markdown_dir (Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts");
      let store = Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
      f config store root))

let with_workspace f =
  with_workspace_directory (fun path -> with_workspace_context ~initialize:true path f)

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
  with_reviewer (fun ~base_path ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
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
         (List.exists (function Llm_provider.Types.Image {source=Llm_provider.Types.Base64 data; _} -> Base64.decode_exn data = bytes | _ -> false) blocks);
       Alcotest.(check bool) "shared successful-read projection" true
         (Yojson.Safe.Util.member "evidence_lookup_succeeded" data = `Bool true)
     | Tool_result.Completed {content_blocks=None; _} | Tool_result.Failed _ | Tool_result.Deferred _ ->
       Alcotest.fail (Tool_result.message result));
    on_tool_result ~input result;
    Ok {AR.selected_runtime_id="goal-reviewer";evaluator_execution=None; verdict=Some (AR.Approve "The actual evidence reaches the metric.")})
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

(* This is the actual retained-worker/reviewer-hook boundary, not HTTP or a
   vendor-model verdict. Assertions stay outside the reviewer callback: AR
   turns a raised callback into a typed evaluator error. *)
let test_reported_measurement_snapshot_reaches_retained_worker () =
  with_workspace (fun config store _ ->
    let goal_id = pending config in
    let goal = match Goal_store.find_goal config ~goal_id with
      | Goal_store.Goal_found goal -> goal
      | Goal_absent | Store_unavailable _ -> Alcotest.fail "pending Goal is absent" in
    let record value evidence actor =
      let receipt = get (Goal_measurement.record config ~goal_id
        ~criterion_revision:goal.criterion_revision ~observed_value:value
        ~evidence ~actor |> Result.map_error Goal_measurement.error_to_string) in
      receipt.Goal_measurement.measurement in
    let first = record "100" "note:https://example.invalid/proof/first" "first-reporter" in
    let authority = get (A.create_goal_review ~config ~goal_id) in
    Alcotest.(check bool) "authority captures the actual complete first report" true
      (A.goal_review_measurement authority = Ok (Some first));
    let original = get (V.prepare ~attempt:0 ~authority) in
    let subject = V.subject original in
    let identity : W.run_identity = {
      run_id="measurement-review/" ^ subject.request_id; started_at=Time_compat.now ()} in
    let retained = checked (W.retain ~store ~installation_id ~package_id ~run:identity original) in
    let original_bytes = Yojson.Safe.to_string (V.to_json original) in
    let first_json = Yojson.Safe.to_string (`Assoc [
      "state", `String "reported";
      "record", `Assoc [
        "id", `String first.id; "goal_id", `String goal_id;
        "criterion_revision", `String goal.criterion_revision;
        "observed_value", `String "100";
        "evidence", `String "note:https://example.invalid/proof/first";
        "actor", `String "first-reporter"; "recorded_at", `String first.recorded_at]]) in
    let updated = record "200" "note:https://example.invalid/proof/updated" "updated-reporter" in
    let updated_authority = get (A.create_goal_review ~config ~goal_id) in
    Alcotest.(check bool) "fresh authority sees the changed same-criterion report" true
      (A.goal_review_measurement updated_authority = Ok (Some updated));
    Alcotest.(check string) "a report update grants exactly the same lookup authority"
      (A.goal_review_binding authority) (A.goal_review_binding updated_authority);
    Alcotest.(check bool) "changed report does not revoke the captured original" true
      (V.matches_authority original updated_authority);
    let calls = ref 0 and received = ref [] and lookup_results = ref [] in
    with_reviewer (fun ~base_path ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
        ?system_prompt ?goal_blocks:_ ~report_tool_schema:_ ~lookup ~on_tool_result
        ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls;
      received := (base_path, prompt, system_prompt) :: !received;
      let input = `Assoc ["file_path", `String measurement_path] in
      let result = lookup.AR.dispatch ~name:"tool_read_file" ~args:input in
      lookup_results := result :: !lookup_results;
      on_tool_result ~input result;
      Ok {AR.selected_runtime_id="goal-reviewer"; evaluator_execution=None;
        verdict=Some (AR.Approve "Fixture observed the actual source value.")}) (fun () ->
      let first_receipt = checked (run store retained updated_authority) in
      Alcotest.(check int) "one actual reviewer entry after the report changed" 1 !calls;
      let actual_prompt = match !received with
        | [(base_path, prompt, system_prompt)] ->
          Alcotest.(check string) "actual consumer receives the captured workspace" config.base_path base_path;
          Alcotest.(check (option string)) "actual consumer receives the captured system instructions"
            (Some (V.system_instructions original)) system_prompt;
          prompt
        | _ -> Alcotest.fail "the reviewer did not receive exactly one original" in
      Alcotest.(check string) "actual reviewer receives immutable original prompt" (V.prompt original) actual_prompt;
      Alcotest.(check bool) "full first report JSON includes value, evidence URL, ID, actor and time" true
        (String_util.contains_substring actual_prompt first_json);
      let updated_json = Goal_measurement.observation_to_yojson (Ok (Some updated))
        |> Yojson.Safe.to_string in
      Alcotest.(check bool) "fresh report does not replace the retained reviewer input" false
        (String_util.contains_substring actual_prompt updated_json);
      (match !lookup_results with
       | [Tool_result.Completed {data; _}] ->
         Alcotest.(check bool) "actual lookup reports completed evidence" true
           (Yojson.Safe.Util.member "evidence_lookup_succeeded" data = `Bool true);
         let document = match Yojson.Safe.Util.member "lookup_result" data with
           | `String text -> Yojson.Safe.from_string text
           | json -> json in
         let content = Yojson.Safe.Util.(member "content" document |> to_string) in
         Alcotest.(check int) "actual shared-playground file still measures 100" 100
           Yojson.Safe.Util.(Yojson.Safe.from_string content |> member "value" |> to_int)
       | _ -> Alcotest.fail "the actual measurement source was not read successfully");
      Alcotest.(check bool) "callback errors cannot masquerade as a judged fixture" true
        (first_receipt.result.verdict = Some (AR.Approve "Fixture observed the actual source value."));
      (match first_receipt.tools with
       | [tool] ->
         Alcotest.(check string) "worker retains its actual file consumer" "tool_read_file" tool.tool_name;
         Alcotest.(check bool) "worker retains the exact read and completed outcome" true
           (tool.input = `Assoc ["file_path", `String measurement_path]
            && tool.disposition = Tool_result.Completed ())
       | _ -> Alcotest.fail "the actual lookup observation was not retained");
      let restored_store = Lane_addon_store.create ~root:(Lane_addon_store.root store) in
      let restored = load restored_store original in
      Alcotest.(check string) "all original bytes survive report update and store reopening"
        original_bytes (Yojson.Safe.to_string (V.to_json (W.original restored)));
      let assert_restored authority =
        let receipt = match checked (W.restored_receipt restored) with
          | Some receipt -> receipt | None -> Alcotest.fail "original judgment was not restored" in
        Alcotest.(check bool) "original result and actual lookup survive" true
          (receipt = first_receipt);
        Alcotest.(check bool) "worker reuses that receipt without consulting a new report" true
          (checked (W.run ~store:restored_store ~retained:restored ~authority
            ~provider_rest:(fun _ -> AR.No_stated_rest) ()) = first_receipt);
        Alcotest.(check int) "restoration never reenters the reviewer" 1 !calls in
      assert_restored updated_authority;
      Out_channel.with_open_bin (Goal_measurement.path config)
        (fun out -> output_string out "{unreadable measurement snapshot");
      let unavailable_authority = get (A.create_goal_review ~config ~goal_id) in
      (match A.goal_review_measurement unavailable_authority with
       | Error _ -> () | Ok _ -> Alcotest.fail "unreadable source became a missing or reported measurement");
      Alcotest.(check string) "unavailable informational source changes no lookup grant"
        (A.goal_review_binding authority) (A.goal_review_binding unavailable_authority);
      Alcotest.(check bool) "source unavailability does not revoke the retained original" true
        (V.matches_authority original unavailable_authority);
      assert_restored unavailable_authority;
      Alcotest.(check string) "unavailable source never rewrites the retained original"
        original_bytes (Yojson.Safe.to_string (V.to_json
          (W.original (load restored_store original))));
      (match Goal_store.find_goal config ~goal_id with
       | Goal_store.Goal_found current ->
         Alcotest.(check bool) "worker input and synthetic verdict never commit Goal proof" true
           (current.phase = Goal_phase.Verifying)
       | Goal_absent | Store_unavailable _ -> Alcotest.fail "original Goal disappeared");
      match get (Goal_verification.get_record_authoritative config ~goal_id) with
      | Some {completion=Goal_verification.Proof_pending pending; _} ->
        Alcotest.(check string) "the same pending proof request remains" subject.request_id pending.request_id
      | None | Some _ -> Alcotest.fail "worker fixture advanced the proof ledger"))

let test_unknown_and_cancellation_never_redispatch () =
  with_workspace (fun config store _ ->
    let authority, retained = prepared config store in
    let calls = ref 0 in
    with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
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
    with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
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
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
      ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls; Ok {AR.selected_runtime_id="goal-reviewer";evaluator_execution=None; verdict=Some (AR.Approve "admitted")}) (fun () ->
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
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
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
    with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
        ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
        ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls;
      Alcotest.(check string) "retry keeps complete original prompt" (V.prompt original) prompt;
      if !calls = 1 then Error (Agent_core.Error.Api (Agent_core.Error.Retry.RateLimited
        {retry_after=Some 1.; message="definite temporary refusal"}))
      else Ok {AR.selected_runtime_id="goal-reviewer";evaluator_execution=None; verdict=Some (AR.Approve "checked original")}) (fun () ->
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
          |> Result.map_error Lane_addon_tool_request_owner.update_error_to_string));
        let orphan = Yojson.Safe.to_string (`String "unreferenced interrupted retain") in
        get (Lane_addon_store.save_tool_request_body store ~scope:"unused-scope"
          ~request_digest:(Lane_addon_store.digest orphan) orphan);
        let report = get (Lane_addon_orphan_body_sweep.run ~store
          |> Result.map_error Lane_addon_orphan_body_sweep.error_to_string) in
        Alcotest.(check int) "restart removes the orphan while retaining the staged Goal input" 1 report.removed);
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

let test_subdivided_parent_requires_retained_unknown_child () =
  with_workspace (fun config store _ ->
    let authority, retained = prepared config store in
    let original = W.original retained in
    let subject = V.subject original in
    let calls = ref 0 in
    with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
        ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
        ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls;
      Alcotest.(check string) "unknown child keeps the original prompt" (V.prompt original) prompt;
      if !calls = 1 then Error (Agent_core.Error.Api (Agent_core.Error.Retry.RateLimited
        {retry_after=Some 1.; message="definite temporary refusal"}))
      else Ok {AR.selected_runtime_id="goal-reviewer";evaluator_execution=None;
        verdict=Some (AR.Approve "checked original")}) (fun () ->
      let refusal = checked (run store retained authority) in
      Alcotest.(check bool) "typed refusal retains retry candidate" true
        (refusal.result.retryable_runtimes <> []);
      let child = get (V.successor original) in
      let fixed_run : W.run_identity = {run_id="fixed-unknown-child/" ^ subject.request_id;
        started_at=Time_compat.now ()} in
      let staged_store = Lane_addon_store.create
        ~root:(Filename.concat (Workspace.masc_dir config) "staged-unknown-child") in
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
        |> Result.map_error Lane_addon_tool_request_owner.update_error_to_string));
      let parent_after_intent = only (load_scope store) in
      ignore (get (Lane_addon_tool_request_owner.advance ~store ~expected:parent_after_intent
        ~event:(P.Successor_observed successor.request_id)
        |> Result.map_error Lane_addon_tool_request_owner.update_error_to_string));
      (match P.phase (W.progress (load store original)) with
       | P.Subdivided _ -> ()
       | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
       | Finished _ | Conflicted _ | Rejected _ | Subdividing _ ->
         Alcotest.fail "fixture must retain a Subdivided parent without its child");
      let allocations = ref 0 in
      (match W.frontier ~store ~installation_id ~package_id
        ~goal_id:subject.goal_id ~request_id:subject.request_id
        ~new_run:(fun () -> incr allocations; fixed_run) with
       | Error (W.Original_invalid _) -> ()
       | Error _ | Ok _ -> Alcotest.fail "missing unknown child was recreated from staged input");
      Alcotest.(check int) "only the original review happened" 1 !calls;
      Alcotest.(check int) "no new run was allocated for a missing unknown child" 0 !allocations))

let test_actual_goal_commit_reply_loss_and_conflict () =
  let exercise conflict = with_workspace (fun config store _ ->
    let authority, retained = prepared config store in
    let original = W.original retained in
    let subject = V.subject original in
    let calls = ref 0 in
    with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
        ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
        ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls; Ok {AR.selected_runtime_id="goal-reviewer";evaluator_execution=None; verdict=Some (AR.Approve "actual proof")}) (fun () ->
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
  fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup ~on_tool_result
      ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls;
    let input = `Assoc ["file_path", `String measurement_path] in
    let result = lookup.AR.dispatch ~name:"tool_read_file" ~args:input in
    if not (Tool_result.is_success result) then Alcotest.fail (Tool_result.message result);
    on_tool_result ~input result;
    Ok {AR.selected_runtime_id="goal-reviewer";evaluator_execution=None; verdict=Some verdict}
let actual_approve calls = actual_review (AR.Approve "actual target measured") calls

let corrupt_host_original_body store retained =
  let module Owner = Lane_addon_tool_request_owner in
  let original = W.original retained in
  let subject = V.subject original in
  let owner_key = Yojson.Safe.to_string
    (`List [`String subject.goal_id; `String subject.request_id; `Int (V.attempt original)]) in
  let scope = "goal-proof-reviews" in
  let record = match Owner.load ~store ~scope ~request_id:owner_key with
    | Ok (Some record) -> record
    | Ok None -> Alcotest.fail "the original body corruption target is absent"
    | Error error -> Alcotest.fail (Owner.error_to_string error) in
  let path = Filename.concat (Lane_addon_store.root store)
    (Lane_addon_store.tool_request_body_path ~scope ~request_digest:record.request_digest) in
  let corrupt_bytes = "{\"damaged_original_body\":true}" in
  (* Only the body of this real retained owner is damaged. Its indexed subject,
     progress and digest stay intact, as do every other owner's bytes. The
     workspace and body path come from this test's private store. *)
  Out_channel.with_open_bin path (fun out -> output_string out corrupt_bytes);
  let assert_preserved () =
    Alcotest.(check string) "damaged original bytes remain unchanged" corrupt_bytes
      (In_channel.with_open_bin path In_channel.input_all);
    match W.load ~store ~installation_id:W.host_installation_id ~package_id:W.host_package_id
      ~goal_id:subject.goal_id ~request_id:subject.request_id ~attempt:(V.attempt original) with
    | Error (W.Store_unavailable _) -> ()
    | Error (Original_invalid _ | Authority_changed _ | Execution_pending _)
    | Ok _ -> Alcotest.fail "damaged own original body did not remain a storage failure"
  in
  assert_preserved ();
  assert_preserved

let assert_host_proof_published ?(registry=R.global ()) config store original =
  let subject = V.subject original in
  let retained = host_load store original in
  let receipt = match checked (W.restored_receipt retained) with
    | Some receipt -> receipt
    | None -> Alcotest.fail "healthy Goal has no retained judgment" in
  Alcotest.(check bool) "healthy proof still requires human confirmation" true
    (phase config subject.goal_id = Goal_phase.Awaiting_confirmation);
  (match get (Goal_verification.get_record_authoritative config ~goal_id:subject.goal_id) with
   | Some {completion=Goal_verification.Proof_proven verdict; _} ->
     Alcotest.(check string) "proof belongs to the original request" subject.request_id verdict.request_id;
     Alcotest.(check string) "proof belongs to the original run" receipt.run.run_id verdict.verification_run_id
   | None | Some _ -> Alcotest.fail "healthy Goal has no actual committed proof");
  (match R.get registry ~run_id:receipt.run.run_id with
   | Some (R.Review {status=R.Completed {outcome=R.Committed; tools; _}; started_at; _}) ->
     Alcotest.(check bool) "terminal publication keeps the actual original observations" true
       (tools <> [] && tools = receipt.tools && started_at = receipt.run.started_at)
   | None | Some (R.Review _ | R.Scan_skipped _) ->
     Alcotest.fail "healthy Goal terminal publication is absent");
  (match P.phase (W.progress retained) with
   | Finished _ -> ()
   | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
   | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
     Alcotest.fail "healthy Goal original commit was not confirmed");
  let observer = P.observer (W.progress retained) in
  List.iter (function
    | Lane_addon_request_receipt.Acknowledged _ -> ()
    | Unobserved | Pending _ -> Alcotest.fail "healthy Goal publication was not acknowledged")
    [observer.registration; observer.completion]

let proof_record_snapshot config goal_id =
  match get (Goal_verification.get_record_authoritative config ~goal_id) with
  | Some ({completion=Goal_verification.Proof_proven _; _} as record) ->
    Yojson.Safe.to_string (Goal_verification.record_to_yojson record)
  | None | Some _ -> Alcotest.fail "restart fixture has no actual committed proof"

let write_proof_before_publication config original (receipt : W.receipt) =
  let subject = V.subject original in
  let verdict : Goal_verification.verdict = {outcome=Goal_verification.Proven;
    request_id=subject.request_id; criterion=subject.criterion; verification_run_id=receipt.run.run_id;
    authority=Workspace_goals.verifier_authority; evidence="actual target measured";
    recorded_at=Masc_domain.now_iso ()} in
  (* Stop after the real proof write and phase reconciliation, before host
     commit/publication ACK. This Goal is no longer in the Verifying scan. *)
  ignore (stored (Goal_store.transact_goal config ~goal_id:subject.goal_id (fun goal ->
    Result.map (fun record -> goal, record) (Goal_verification.record_proof_verdict
      ~before_commit:(fun () -> Candle_snapshot.before_proof_commit config goal verdict)
      config ~goal_id:subject.goal_id verdict))));
  ignore (stored (Workspace_goals.reconcile_committed_proof config ~goal_id:subject.goal_id));
  Alcotest.(check bool) "healthy Goal has left the ordinary pending scan" true
    (phase config subject.goal_id = Goal_phase.Awaiting_confirmation);
  Alcotest.(check bool) "terminal publication was not fabricated before restart" true
    (R.get (R.global ()) ~run_id:receipt.run.run_id = None);
  verdict

let recover_body_fixture (probe : restart_probe) =
  with_workspace_context ~initialize:false probe.base_path (fun config store _ ->
    (* No parent registry object can survive exec. Start from the workspace's
       empty durable registry and read the judgment/run only from its owner. *)
    Alcotest.(check int) "fresh process starts with no published runs" 0
      (List.length (R.list_runs (R.global ())));
    let retained = match checked (W.load ~store ~installation_id:W.host_installation_id
        ~package_id:W.host_package_id ~goal_id:probe.goal_id ~request_id:probe.request_id
        ~attempt:probe.attempt) with
      | Some retained -> retained
      | None -> Alcotest.fail "fresh process cannot find the serialized Goal original" in
    let original = W.original retained in
    (match P.phase (W.progress retained) with
     | Judged _ -> ()
     | Captured | Admission_wait _ | Dispatch_pending _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
       Alcotest.fail "fresh process did not reopen the uncommitted actual judgment");
    Alcotest.(check bool) "recovery is required despite the phase having moved" true
      (hosted (H.needs_recovery ~registry:(R.global ()) retained));
    Alcotest.(check bool) "fresh process sees the committed proof phase" true
      (phase config probe.goal_id = Goal_phase.Awaiting_confirmation);
    let before = proof_record_snapshot config probe.goal_id in
    let calls = ref 0 in
    with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
        ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
        ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls;
      Alcotest.fail "fresh-process recovery must not dispatch a reviewer") (fun () ->
      drain config;
      drain config;
      Alcotest.(check int) "fresh-process recovery makes no model call" 0 !calls;
      assert_host_proof_published config store original;
      Alcotest.(check string) "fresh-process recovery preserves the complete proof record"
        before (proof_record_snapshot config probe.goal_id);
      Alcotest.(check bool) "durable publication leaves no recovery work" false
        (hosted (H.needs_recovery ~registry:(R.global ()) (host_load store original)))))

let run_restart_process (probe : restart_probe) =
  let executable = Unix.realpath Sys.executable_name in
  let child = Unix.create_process executable
    [|executable; restart_argument; probe.base_path; probe.goal_id; probe.request_id;
      string_of_int probe.attempt|] Unix.stdin Unix.stdout Unix.stderr in
  let rec wait () =
    match Unix.waitpid [] child with
    | _, status -> status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait () in
  match wait () with
  | Unix.WEXITED 0 -> ()
  | WEXITED code -> Alcotest.failf "Goal recovery child exited %d" code
  | WSIGNALED signal -> Alcotest.failf "Goal recovery child was killed by signal %d" signal
  | WSTOPPED signal -> Alcotest.failf "Goal recovery child stopped on signal %d" signal

let test_actual_pending_goal_survives_foreign_body_corruption () =
  with_workspace (fun config store _ ->
    let _, damaged = host_prepared config store in
    let _, healthy = host_prepared config store in
    let damaged_subject = V.subject (W.original damaged) in
    let healthy_original = W.original healthy in
    let healthy_subject = V.subject healthy_original in
    Alcotest.(check bool) "fixture subjects are independent Goals" false
      (damaged_subject.goal_id = healthy_subject.goal_id);
    let assert_damaged = corrupt_host_original_body store damaged in
    let calls = ref 0 in
    with_reviewer (actual_approve calls) (fun () ->
      let outcome = Agent.process_pending_work config {Agent.goal_id=healthy_subject.goal_id} in
      assert_damaged ();
      (match outcome with
       | Agent.Committed -> ()
       | Superseded -> Alcotest.fail "healthy Goal was superseded by another subject's body failure"
       | Deferred deferral -> Alcotest.failf "healthy Goal blocked by foreign body: %s"
           (Agent.deferral_detail deferral));
      assert_host_proof_published config store healthy_original;
      Alcotest.(check int) "one actual healthy review reaches publication" 1 !calls;
      (match Agent.process_pending_work config {Agent.goal_id=damaged_subject.goal_id} with
       | Deferred (Proof_lookup_unavailable _) -> ()
       | Deferred _ | Committed | Superseded ->
         Alcotest.fail "damaged Goal did not retain its explicit original lookup failure");
      drain config;
      assert_damaged ();
      Alcotest.(check bool) "damaged Goal remains pending" true
        (phase config damaged_subject.goal_id = Goal_phase.Verifying);
      Alcotest.(check int) "later wake does not repeat either original effect" 1 !calls))

let retain_unattributable_metadata store =
  get (Lane_addon_tool_request_owner.retain ~store ~scope:"goal-proof-reviews"
    ~request_id:"malformed" ~installation_id:W.host_installation_id
    ~package_id:W.host_package_id ~tool:"goal_proof_review"
    ~summary:(`Assoc []) ~request:(`Assoc [])
    |> Result.map_error Lane_addon_tool_request_owner.error_to_string)

let retain_noncanonical_metadata store ~goal_id ~request_id ~attempt =
  let noncanonical = Yojson.Safe.to_string
    (`List [`String goal_id; `String request_id; `Int attempt]) ^ " " in
  get (Lane_addon_tool_request_owner.retain ~store ~scope:"goal-proof-reviews"
    ~request_id:noncanonical ~installation_id:W.host_installation_id
    ~package_id:W.host_package_id ~tool:"goal_proof_review"
    ~summary:(`Assoc []) ~request:(`Assoc [])
    |> Result.map_error Lane_addon_tool_request_owner.error_to_string)

let test_actual_pending_goal_survives_unattributable_foreign_metadata () =
  with_workspace (fun config store _ ->
    let _, healthy = host_prepared config store in
    let healthy_original = W.original healthy in
    ignore (retain_unattributable_metadata store);
    let calls = ref 0 in
    with_reviewer (actual_approve calls) (fun () ->
      drain config;
      assert_host_proof_published config store healthy_original;
      Alcotest.(check int) "foreign malformed metadata does not block a valid original" 1 !calls))

let test_unattributable_metadata_never_starts_new_review () =
  with_workspace (fun config store _ ->
    ignore (retain_unattributable_metadata store);
    let goal_id = pending config in
    let calls = ref 0 in
    with_reviewer (actual_approve calls) (fun () ->
      (match Agent.process_pending_work config {Agent.goal_id} with
       | Agent.Deferred (Agent.Proof_lookup_unavailable _) -> ()
       | Agent.Committed | Agent.Superseded | Agent.Deferred _ ->
         Alcotest.fail "unattributable metadata authorized a fresh review");
      Alcotest.(check bool) "unknown original remains pending" true
        (phase config goal_id = Goal_phase.Verifying);
      Alcotest.(check int) "unknown original never dispatches a reviewer" 0 !calls))

let expect_noncanonical_neighbor_to_commute config store goal_id =
  (match Agent.process_pending_work config {Agent.goal_id} with
   | Agent.Committed -> ()
   | Agent.Superseded -> Alcotest.fail "foreign noncanonical key superseded the new Goal"
   | Agent.Deferred deferral -> Alcotest.failf "foreign noncanonical key blocked the new Goal: %s"
       (Agent.deferral_detail deferral));
  match checked (W.inventory_for_goal ~store ~installation_id:W.host_installation_id
    ~package_id:W.host_package_id ~goal_id) with
  | [retained] -> assert_host_proof_published config store (W.original retained)
  | [] | _::_ -> Alcotest.fail "new Goal did not retain exactly one actual original"

let test_noncanonical_other_goal_does_not_block_new_review () =
  with_workspace (fun config store _ ->
    let goal_id = pending config in
    ignore (retain_noncanonical_metadata store ~goal_id:"other-goal" ~request_id:"other-request" ~attempt:0);
    let calls = ref 0 in
    with_reviewer (actual_approve calls) (fun () ->
      expect_noncanonical_neighbor_to_commute config store goal_id;
      Alcotest.(check int) "another Goal's noncanonical key permits one actual review" 1 !calls))

let test_noncanonical_previous_request_does_not_block_new_review () =
  with_workspace (fun config store _ ->
    let goal_id = pending config in
    ignore (retain_noncanonical_metadata store ~goal_id ~request_id:"previous-request" ~attempt:0);
    let calls = ref 0 in
    with_reviewer (actual_approve calls) (fun () ->
      expect_noncanonical_neighbor_to_commute config store goal_id;
      Alcotest.(check int) "a previous request's noncanonical key permits one actual review" 1 !calls))

let test_noncanonical_same_request_never_starts_new_review () =
  with_workspace (fun config store _ ->
    let goal_id = pending config in
    let authority = get (A.create_goal_review ~config ~goal_id) in
    let request_id = (A.goal_review_subject authority).request_id in
    ignore (retain_noncanonical_metadata store ~goal_id ~request_id ~attempt:0);
    let calls = ref 0 in
    with_reviewer (actual_approve calls) (fun () ->
      (match Agent.process_pending_work config {Agent.goal_id} with
       | Agent.Deferred (Agent.Proof_lookup_unavailable _) -> ()
       | Agent.Committed | Agent.Superseded | Agent.Deferred _ ->
         Alcotest.fail "matching noncanonical metadata authorized a fresh review");
      Alcotest.(check bool) "matching noncanonical original remains pending" true
        (phase config goal_id = Goal_phase.Verifying);
      Alcotest.(check int) "matching noncanonical original never dispatches a reviewer" 0 !calls))

let test_noncanonical_successor_blocks_automatic_retry () =
  with_workspace (fun config store _ ->
    let authority, retained = prepared config store in
    let original = W.original retained in
    let subject = V.subject original in
    let calls = ref 0 in
    with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
        ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
        ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls;
      Error (Agent_core.Error.Api (Agent_core.Error.Retry.RateLimited
        {retry_after=Some 1.; message="definite temporary refusal"}))) (fun () ->
      let refusal = checked (run store retained authority) in
      Alcotest.(check bool) "fixture retains a retryable canonical parent" true
        (refusal.result.retryable_runtimes <> []);
      ignore (retain_noncanonical_metadata store ~goal_id:subject.goal_id
        ~request_id:subject.request_id ~attempt:1);
      let allocations = ref 0 in
      let outcome = W.frontier ~store ~installation_id ~package_id
        ~goal_id:subject.goal_id ~request_id:subject.request_id
        ~new_run:(fun () ->
          incr allocations;
          {run_id="noncanonical-successor-must-not-run/" ^ subject.request_id;
            started_at=Time_compat.now ()}) in
      Alcotest.(check int) "noncanonical successor cannot allocate a new run" 0 !allocations;
      match outcome with
      | Error (W.Original_invalid _) -> ()
      | Error _ | Ok _ -> Alcotest.fail "noncanonical successor was replaced by a fresh retry"))

let test_actual_boot_publication_survives_foreign_body_corruption () =
  with_workspace (fun config store _ ->
    let _, damaged = host_prepared config store in
    let authority, healthy = host_prepared config store in
    let original = W.original healthy in
    let subject = V.subject original in
    let calls = ref 0 in
    with_reviewer (actual_approve calls) (fun () ->
      let receipt = checked (run store healthy authority) in
      let verdict = write_proof_before_publication config original receipt in
      let assert_damaged = corrupt_host_original_body store damaged in
      let reopened_store = Lane_addon_store.create ~root:(Lane_addon_store.root store) in
      let reopened_config = Workspace.default_config config.base_path in
      (match P.phase (W.progress (host_load reopened_store original)) with
       | Judged _ -> ()
       | Captured | Admission_wait _ | Dispatch_pending _ | Committing _ | Commit_unknown _
       | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
         Alcotest.fail "restart fixture lost the actual uncommitted judgment");
      drain reopened_config;
      drain reopened_config;
      assert_damaged ();
      Alcotest.(check int) "boot recovery does not invoke another model" 1 !calls;
      assert_host_proof_published reopened_config reopened_store original;
      match get (Goal_verification.get_record_authoritative reopened_config ~goal_id:subject.goal_id) with
      | Some {completion=Goal_verification.Proof_proven restored; _} ->
        Alcotest.(check string) "boot recovery preserves the first committed proof timestamp"
          verdict.recorded_at restored.recorded_at
      | None | Some _ -> Alcotest.fail "boot recovery lost the actual proof"))

let test_actual_process_restart_survives_foreign_body_corruption () =
  with_workspace_directory (fun path ->
    let probe, original, before, assert_damaged =
      with_workspace_context ~initialize:true path (fun config store _ ->
        let _, damaged = host_prepared config store in
        let authority, healthy = host_prepared config store in
        let original = W.original healthy in
        let subject = V.subject original in
        let calls = ref 0 in
        with_reviewer (actual_approve calls) (fun () ->
          let receipt = checked (run store healthy authority) in
          ignore (write_proof_before_publication config original receipt);
          Alcotest.(check int) "parent performed one actual review before exiting its context" 1 !calls;
          let assert_damaged = corrupt_host_original_body store damaged in
          let probe = {base_path=config.base_path; goal_id=subject.goal_id;
            request_id=subject.request_id; attempt=V.attempt original} in
          probe, original, proof_record_snapshot config subject.goal_id, assert_damaged)) in
    (* The Eio context and reviewer override have both ended before a fresh
       executable reopens the private durable state. *)
    run_restart_process probe;
    with_workspace_context ~initialize:false path (fun config store _ ->
      assert_damaged ();
      Alcotest.(check string) "child preserved the parent's complete committed proof"
        before (proof_record_snapshot config probe.goal_id);
      let registry = R.replay (Filename.concat (Workspace.masc_dir config) R.storage_filename) in
      assert_host_proof_published ~registry config store original;
      Alcotest.(check bool) "child completion ACK survives registry replay" false
        (hosted (H.needs_recovery ~registry (host_load store original)))))

let test_actual_host_refuses_own_body_corruption () =
  with_workspace (fun config store _ ->
    let _, retained = host_prepared config store in
    let subject = V.subject (W.original retained) in
    let assert_damaged = corrupt_host_original_body store retained in
    let calls = ref 0 in
    with_reviewer (actual_approve calls) (fun () ->
      let outcome = Agent.process_pending_work config {Agent.goal_id=subject.goal_id} in
      assert_damaged ();
      (match outcome with
       | Deferred (Proof_lookup_unavailable _) -> ()
       | Deferred _ | Committed | Superseded ->
         Alcotest.fail "own body corruption was treated as permission to verify");
      Alcotest.(check int) "own corrupt original cannot dispatch the model" 0 !calls;
      Alcotest.(check bool) "own corrupt original does not advance Goal phase" true
        (phase config subject.goal_id = Goal_phase.Verifying);
      match get (Goal_verification.get_record_authoritative config ~goal_id:subject.goal_id) with
      | Some {completion=Goal_verification.Proof_pending pending; _} ->
        Alcotest.(check string) "same proof request remains pending" subject.request_id pending.request_id
      | None | Some _ -> Alcotest.fail "own corrupt original changed the proof request"))

let test_actual_integral_receipt_commits_after_restart () = with_workspace (fun config store _ ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 42.;
  Time_compat.set_clock (clock :> float Eio.Time.clock_ty Eio.Resource.t);
  Fun.protect ~finally:Time_compat.clear_clock (fun () ->
    let authority, retained = host_prepared config store in
    let original = W.original retained in
    let subject = V.subject original in
    let calls = ref 0 in
    with_reviewer (actual_approve calls) (fun () ->
      ignore (checked (run store retained authority));
      let store = Lane_addon_store.create ~root:(Lane_addon_store.root store) in
      let retained = host_load store original in
      let judgment = checked (W.retained_judgment retained) in
      Alcotest.(check bool) "the actual owner canonicalized integral receipt metadata" true
        (Yojson.Safe.Util.(judgment |> member "elapsed_s") = `Int 0
          && Yojson.Safe.Util.(judgment |> member "run" |> member "started_at") = `Int 42);
      let changed = match judgment with
        | `Assoc fields -> `Assoc (("elapsed_s", `Int 1) :: List.remove_assoc "elapsed_s" fields)
        | _ -> Alcotest.fail "actual retained judgment is not an object" in
      let after = `Assoc ["original_digest", `String (get (V.digest original)); "receipt", changed] in
      (match W.commit ~store ~retained ~change:{P.before=`Null; after}
          ~observe:(fun _ -> Alcotest.fail "changed receipt reached domain observation")
          ~apply:(fun _ -> Alcotest.fail "changed receipt reached domain application") with
       | Error (W.Original_invalid _) -> ()
       | Ok () | Error _ -> Alcotest.fail "modified original receipt was admitted");
      drain config;
      drain config;
      Alcotest.(check int) "restart and repeated recovery do not ask another model" 1 !calls;
      Alcotest.(check bool) "integral original metadata commits the actual proof" true
        (phase config subject.goal_id=Goal_phase.Awaiting_confirmation);
      match get (Goal_verification.get_record_authoritative config ~goal_id:subject.goal_id) with
      | Some {completion=Goal_verification.Proof_proven verdict; _} ->
        Alcotest.(check string) "proof keeps the original run" (W.run_identity retained).run_id verdict.verification_run_id
      | None | Some _ -> Alcotest.fail "actual integral receipt did not retain its proof")))

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
    with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
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
      (match R.get (R.global ()) ~run_id:receipt.run.run_id with
       | Some (R.Review {status=R.Completed {outcome=R.Deferred _; evaluated_verdict=None; tools; _}; _}) ->
         Alcotest.(check bool) "published non-verdict preserves the actual raw tool observations" true
           (tools=receipt.tools)
       | None | Some (R.Review _ | R.Scan_skipped _) ->
         Alcotest.fail "reasonless receipt was not published as a valid deferred non-verdict");
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
        Alcotest.(check bool) "resume restores the original verifying phase before its wake is consumed" true
          (phase config subject.goal_id=Goal_phase.Verifying);
        drain config;
        Alcotest.(check bool) "resume reconciles proof without human completion" true
          (phase config subject.goal_id=Goal_phase.Awaiting_confirmation);
        Alcotest.(check int) "the actual resume consumer reuses the committed proof" 1 !calls))) in
  exercise false;
  exercise true

let test_finished_publication_survives_registry_retention () = with_workspace (fun config store _ ->
  let authority, retained = host_prepared config store in
  let original = W.original retained in
  let calls = ref 0 in
  with_reviewer (actual_approve calls) (fun () ->
    ignore (checked (run store retained authority));
    let registry_path = Filename.concat config.base_path "goal-review-history.jsonl" in
    let registry = R.replay registry_path in
    let original_run = W.run_identity retained in
    let subject = V.subject original in
    (* Complete newer observations first: the original is immediately pruned
       on its first publication, not only after a prior acknowledgement. *)
    for index = 1 to R.max_completed_retained do
      let run_id = Printf.sprintf "newer-observation/%d" index in
      R.register_running registry ~run_id ~goal_id:subject.goal_id ~request_id:subject.request_id
        ~criterion:subject.criterion ~review_kind:R.Proof ~authority_actor:"verifier_exact"
        ~started_at:(original_run.started_at +. float_of_int index);
      R.mark_completed registry ~run_id ~outcome:(R.Deferred {detail="newer observation"}) ~evaluated_verdict:None
        ~tools:[] ~elapsed_s:0. ()
    done;
    hosted (H.commit_proof ~config ~store ~registry (host_load store original));
    Alcotest.(check bool) "actual retention immediately removes the oldest display row" true
      (R.get registry ~run_id:original_run.run_id = None);
    let restored_store = Lane_addon_store.create ~root:(Lane_addon_store.root store) in
    let restored = host_load restored_store original in
    let replayed = R.replay registry_path in
    let before = In_channel.with_open_bin registry_path In_channel.input_all in
    Alcotest.(check bool) "durable original ACK survives registry replay and pruning" false
      (hosted (H.needs_recovery ~registry:replayed restored));
    Alcotest.(check bool) "rechecking does not append another observation" false
      (hosted (H.needs_recovery ~registry:replayed restored));
    Alcotest.(check string) "history remains unchanged" before
      (In_channel.with_open_bin registry_path In_channel.input_all);
    Alcotest.(check int) "no reviewer redispatch" 1 !calls))

let reviewer_exit_after_actual_lookup calls ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
    ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup ~on_tool_result
    ~attempt_continuation:_ ~on_runtime_attempt_error:_ () =
  incr calls;
  let input = `Assoc ["file_path", `String measurement_path] in
  let result = lookup.AR.dispatch ~name:"tool_read_file" ~args:input in
  if not (Tool_result.is_success result) then Alcotest.fail (Tool_result.message result);
  on_tool_result ~input result;
  raise Exit

let test_caught_reviewer_exit_retains_actual_unknown_receipt () = with_workspace (fun config store _ ->
  let authority,retained = host_prepared config store in
  let original = W.original retained in
  let calls = ref 0 in
  with_reviewer (reviewer_exit_after_actual_lookup calls) (fun () ->
    (match run store retained authority with
     | Error (W.Execution_pending _) -> ()
     | Ok _ | Error _ -> Alcotest.fail "caught reviewer error did not retain an unknown dispatch");
    let restored_store = Lane_addon_store.create ~root:(Lane_addon_store.root store) in
    let restored = host_load restored_store original in
    let receipt = match checked (W.observed_receipt restored) with
      | Some receipt -> receipt | None -> Alcotest.fail "caught reviewer error lost its raw result" in
    let caught_error = Agent_core.Error.Internal
      (Printf.sprintf "review evaluator raised unexpectedly: %s" (Printexc.to_string Exit)) in
    Alcotest.(check bool) "caught Exit retains the typed unavailable non-verdict" true
      (receipt.result.verdict=None && receipt.result.gate=AR.Evaluator_unavailable
       && receipt.result.retryable_runtimes=[]);
    Alcotest.(check (option string)) "raw caught Internal error survives reopening"
      (Some (Agent_core.Error.to_string caught_error)) receipt.result.fallback_reason;
    let tools = checked (W.tool_observations restored) in
    Alcotest.(check bool) "caught reviewer error retains its actual lookup" true
      (tools=receipt.tools && List.exists (fun (tool : Verification_run_registry.tool_observation) ->
        tool.tool_name="tool_read_file") tools);
    let registry = R.replay (Filename.concat config.base_path "caught-review-history.jsonl") in
    hosted (H.publish ~store:restored_store ~registry restored
      ~outcome:(R.Deferred {detail="caught reviewer error"}));
    (match R.get registry ~run_id:receipt.run.run_id with
     | Some (R.Review {status=R.Completed {outcome=R.Deferred _; evaluated_verdict=None; tools=observed; _}; _}) ->
       Alcotest.(check bool) "caught error publishes its actual tools as deferred" true (observed=tools)
     | None | Some (R.Review _ | R.Scan_skipped _) -> Alcotest.fail "caught error observation is absent");
    (match run restored_store restored authority with
     | Error (W.Execution_pending _) -> ()
     | Ok _ | Error _ -> Alcotest.fail "caught reviewer error redispatched its unknown original");
    Alcotest.(check int) "caught reviewer is never replayed" 1 !calls))

let test_raised_review_retains_actual_tool_observation () = with_workspace (fun config store _ ->
  let exception Observation_failed in
  let authority,retained = host_prepared config store in
  let original = W.original retained in
  let calls = ref 0 and observer_calls = ref 0 in
  with_reviewer (reviewer_exit_after_actual_lookup calls) (fun () ->
      let old_observer = Atomic.get AR.outcome_observer_fn in
      Fun.protect ~finally:(fun () -> Atomic.set AR.outcome_observer_fn old_observer) (fun () ->
        (* The reviewer Exit becomes typed Internal inside AR. This existing
           post-review observer runs outside that catch boundary and raises
           a distinct exception that must actually escape to the worker. *)
        Atomic.set AR.outcome_observer_fn (fun ~outcome:_ ~runtime:_ ->
          incr observer_calls;
          Alcotest.(check int) "escaping observer follows the actual reviewer lookup" 1 !calls;
          raise Observation_failed);
        (try ignore (run store retained authority); Alcotest.fail "observer exception was swallowed"
         with Observation_failed -> ()));
      Alcotest.(check int) "the original observer exception escaped exactly once" 1 !observer_calls;
      let restored_store = Lane_addon_store.create ~root:(Lane_addon_store.root store) in
      let restored = host_load restored_store original in
      let tools = checked (W.tool_observations restored) in
      Alcotest.(check bool) "actual successful lookup survives exception and reload" true
        (List.exists (fun (tool : Verification_run_registry.tool_observation) ->
          tool.tool_name="tool_read_file") tools);
      let registry = R.replay (Filename.concat config.base_path "raised-review-history.jsonl") in
      let detail = Printexc.to_string Observation_failed in
      hosted (H.publish ~store:restored_store ~registry restored ~outcome:(R.Raised {detail}));
      (match R.get registry ~run_id:(W.run_identity retained).run_id with
       | Some (R.Review {status=R.Completed {outcome=R.Raised {detail=observed_detail}; tools=observed; _}; _}) ->
         Alcotest.(check string) "Raised names the actual escaping observer exception" detail observed_detail;
         Alcotest.(check bool) "raised host observation preserves the actual tools" true (observed=tools)
       | None | Some (R.Review _ | R.Scan_skipped _) -> Alcotest.fail "raised observation is absent");
      (match run restored_store restored authority with
       | Error (W.Execution_pending _) -> ()
       | Ok _ | Error _ -> Alcotest.fail "raised review redispatched its unknown original");
      Alcotest.(check int) "raised reviewer is never replayed" 1 !calls))

let () = match restart_probe with
| Some probe -> recover_body_fixture probe
| None -> Alcotest.run "retained Goal worker" ["execution", [
  Alcotest.test_case "actual retained visual lookup and restart receipt" `Quick test_actual_retained_lookup_and_restored_receipt;
  Alcotest.test_case "reported measurement reaches retained worker without changing recovery authority" `Quick test_reported_measurement_snapshot_reaches_retained_worker;
  Alcotest.test_case "unknown and cancellation never redispatch" `Quick test_unknown_and_cancellation_never_redispatch;
  Alcotest.test_case "same-original pre-admission repair" `Quick test_pre_admission_repair_keeps_original;
  Alcotest.test_case "authority destination and strict inventory" `Quick test_destination_authority_and_inventory;
  Alcotest.test_case "linked frontier restores the original staged run" `Quick test_linked_frontier_and_staged_run_recovery;
  Alcotest.test_case "Subdivided parent requires retained unknown child" `Quick test_subdivided_parent_requires_retained_unknown_child;
  Alcotest.test_case "actual Goal proof commit reply loss and conflict" `Quick test_actual_goal_commit_reply_loss_and_conflict;
  Alcotest.test_case "actual pending Goal survives foreign original body corruption" `Quick
    test_actual_pending_goal_survives_foreign_body_corruption;
  Alcotest.test_case "actual pending Goal survives unattributable foreign metadata" `Quick
    test_actual_pending_goal_survives_unattributable_foreign_metadata;
  Alcotest.test_case "unattributable metadata never starts a new review" `Quick
    test_unattributable_metadata_never_starts_new_review;
  Alcotest.test_case "noncanonical other Goal does not block a new review" `Quick
    test_noncanonical_other_goal_does_not_block_new_review;
  Alcotest.test_case "noncanonical previous request does not block a new review" `Quick
    test_noncanonical_previous_request_does_not_block_new_review;
  Alcotest.test_case "noncanonical matching request never starts a new review" `Quick
    test_noncanonical_same_request_never_starts_new_review;
  Alcotest.test_case "noncanonical successor blocks automatic retry" `Quick
    test_noncanonical_successor_blocks_automatic_retry;
  Alcotest.test_case "actual boot publication survives foreign original body corruption" `Quick
    test_actual_boot_publication_survives_foreign_body_corruption;
  Alcotest.test_case "actual process restart survives foreign original body corruption" `Quick
    test_actual_process_restart_survives_foreign_body_corruption;
  Alcotest.test_case "actual host refuses its own original body corruption" `Quick
    test_actual_host_refuses_own_body_corruption;
  Alcotest.test_case "actual integral receipt commits after restart and rejects alteration" `Quick test_actual_integral_receipt_commits_after_restart;
  Alcotest.test_case "actual agent restores before lookup and registry" `Quick test_actual_agent_restores_before_lookup_and_registry;
  Alcotest.test_case "finished publication survives registry retention" `Quick test_finished_publication_survives_registry_retention;
  Alcotest.test_case "caught reviewer Exit retains its actual unknown receipt" `Quick test_caught_reviewer_exit_retains_actual_unknown_receipt;
  Alcotest.test_case "raised review retains actual tool observation" `Quick test_raised_review_retains_actual_tool_observation;
  Alcotest.test_case "actual proof partial write and phase-moved boot" `Quick test_actual_partial_proof_and_nonverifying_boot;
  Alcotest.test_case "actual explicit retry and unknown fence" `Quick test_actual_explicit_retry_and_unknown_fence;
  Alcotest.test_case "reasonless Goal reply needs an explicit linked retry" `Quick test_reasonless_goal_reply_requires_explicit_retry;
  Alcotest.test_case "actual bound suspend and drop" `Quick test_actual_bound_suspend_and_drop;
  Alcotest.test_case "cloned workspace refuses the original judgment" `Quick test_cloned_workspace_cannot_commit_original]]
