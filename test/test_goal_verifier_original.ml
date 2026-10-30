open Masc

module A = Verification_authority_tools
module V = Goal_verifier_original
module Owner = Lane_addon_tool_request_owner
module Evidence = Workspace_verification_store

let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let owner_result = function Ok value -> value | Error error -> Alcotest.fail (Owner.error_to_string error)
let evidence = [Evidence.Evidence_note "The measurement belongs to this exact submission.";
  Evidence.Evidence_artifact {reference="artifact:measurement.json"; content="{\"value\":100}";
    bytes=13; truncated=false}]

let with_initialized_workspace f =
  let path = Filename.temp_dir "goal-original-" "" in
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
      Prompt_registry.set_markdown_dir
        (Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts");
      f config))))

let with_workspace f = with_initialized_workspace (fun config ->
  let root = Filename.concat (Evidence.project_root_of_base_path config.base_path)
    (Playground_paths.bundle_root "measurement-owner") in
  Fs_compat.mkdir_p root;
  f config root)

let stored = function
  | Ok value -> value | Error error -> Alcotest.fail (Goal_store.write_error_to_string error)
let proof = function
  | Ok value -> value
  | Error (Workspace_goals.Store error) -> Alcotest.fail (Goal_store.write_error_to_string error)
  | Error (Workspace_goals.Refused {message; _}) -> Alcotest.fail message
let submit_items config goal_id items =
  ignore (stored (Goal_store.transact_goal config ~goal_id (fun goal ->
    Result.map (fun record -> goal, record) (Goal_verification.mark_proof_pending
      ~submitted_evidence:items config ~goal_id ~criterion:(Goal_store.criterion_of_goal goal)))))
let pending ?id ?(items=evidence) config =
  let goal, _ = stored (Goal_store.upsert_goal config ?id
    ~title:"Measure the actual result" ~metric:"artifact:measurement.json" ~target_value:"100" ()) in
  ignore (proof (Workspace_goals.request_current_proof config ~goal_id:goal.id));
  submit_items config goal.id items;
  goal.id
let authority config goal_id = get (A.create_goal_review ~config ~goal_id)
let original authority = get (V.prepare ~attempt:0 ~authority)

let test_fresh_goal_without_keeper_or_manual_playground () =
  with_initialized_workspace (fun config ->
    let root = Filename.concat config.base_path Playground_paths.all_playgrounds_prefix in
    Alcotest.(check bool) "bootstrap supplies the shared root" true (Sys.is_directory root);
    Alcotest.(check int) "no Keeper or producer was created" 0
      (Array.length (Sys.readdir root));
    let goal, _ = stored (Goal_store.upsert_goal config
      ~title:"Read a public measurement without creating a Keeper"
      ~metric:"https://example.com/measurement.json" ~target_value:"100" ()) in
    let current, requested = proof (Workspace_goals.request_current_proof config ~goal_id:goal.id) in
    let request_id = match requested.Goal_verification.completion with
      | Goal_verification.Proof_pending {request_id; _} -> request_id
      | Completion_idle | Proof_proven _ | Proof_refuted _ | Human_confirmed _ ->
        Alcotest.fail "public proof request did not remain pending" in
    let admitted = authority config goal.id in
    let prepared = original admitted in
    let subject = V.subject prepared in
    Alcotest.(check string) "same Goal" goal.id subject.goal_id;
    Alcotest.(check string) "same request" request_id subject.request_id;
    Alcotest.(check bool) "same criterion" true
      (Goal_store.criterion_equal (Goal_store.criterion_of_goal current) subject.criterion);
    Alcotest.(check bool) "known-empty shared layout" true (V.root_layout prepared = []);
    Unix.rmdir root;
    (match A.create_goal_review ~config ~goal_id:goal.id with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "unavailable shared root was treated as empty");
    Alcotest.(check bool) "read-only authority cannot recreate the root" false
      (Sys.file_exists root);
    ignore (Workspace.init config ~agent_name:None);
    let restored_authority = authority config goal.id in
    ignore (original restored_authority);
    Alcotest.(check bool) "bootstrap repair preserves retained authority" true
      (V.matches_authority prepared restored_authority);
    let after = match Goal_store.find_goal config ~goal_id:goal.id with
      | Goal_store.Goal_found goal -> goal
      | Goal_absent | Store_unavailable _ -> Alcotest.fail "Goal disappeared during preparation" in
    Alcotest.(check bool) "preparation does not prove the Goal" true
      (after.phase = Goal_phase.Verifying);
    let record = match get (Goal_verification.get_record_authoritative config ~goal_id:goal.id) with
      | Some record -> record
      | None -> Alcotest.fail "proof request disappeared during preparation" in
    Alcotest.(check bool) "proof request remains byte-equivalent" true
      (Yojson.Safe.equal (Goal_verification.record_to_yojson requested)
        (Goal_verification.record_to_yojson record)))

let with_changed_prompts f =
  let names = [Prompt_names.goal_verification_proof; Prompt_names.verification_system] in
  let saved = List.map (fun name -> name, Prompt_registry.resolve_prompt name) names in
  Fun.protect ~finally:(fun () -> List.iter (fun (name, before) ->
    match before.Prompt_registry.override_value with
    | None -> Prompt_registry.clear_prompt_override name
    | Some text -> ignore (get (Prompt_registry.set_override name text))) saved) (fun () ->
    List.iter (fun (name, before) ->
      ignore (get (Prompt_registry.set_override name (before.Prompt_registry.effective ^ "\nChanged later.")))) saved;
    f ())

let test_stored_goal_preparation_and_actual_visual_lookup () = with_workspace (fun config root ->
  let source = Filename.concat (Masc_test_deps.find_project_root ()) "test/fixtures/verifier-image-lookup.png" in
  let bytes = In_channel.with_open_bin source In_channel.input_all in
  let image = Filename.concat root "proof.png" in
  Out_channel.with_open_bin image (fun out -> output_string out bytes);
  let image_evidence = Evidence.Evidence_artifact_binary {reference="artifact:proof.png";
    bytes=String.length bytes; sha256=Agent_core_sha256.(digest_string bytes |> to_hex);
    format="image/png"; body=Some image} in
  let goal_id = pending ~items:(evidence @ [image_evidence]) config in
  let authority = authority config goal_id in
  let subject = A.goal_review_subject authority in
  let prepared = original authority in
  let store = Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let digest = get (V.digest prepared) in
  owner_result (Owner.retain ~store ~scope:"goal-proof-original-fixture"
    ~request_id:subject.request_id ~installation_id:"goal-verifier-fixture" ~package_id:"goal-proof-fixture"
    ~tool:"goal_proof_review" ~summary:(`Assoc ["original_digest", `String digest]) ~request:(V.to_json prepared));
  with_changed_prompts (fun () ->
    let restored = match owner_result (Owner.load ~store ~scope:"goal-proof-original-fixture"
        ~request_id:subject.request_id) with
      | Some record -> get (V.of_json record.request)
      | None -> Alcotest.fail "retained original disappeared" in
    Alcotest.(check string) "stored Goal prompt remains exact" (V.prompt prepared) (V.prompt restored);
    Alcotest.(check string) "stored system message remains exact"
      (V.system_instructions prepared) (V.system_instructions restored);
    Alcotest.(check string) "full original digest remains exact" digest (get (V.digest restored));
    Alcotest.(check bool) "same full host capability admits original" true (V.matches_authority restored authority);
    Alcotest.(check bool) "complete original evidence survives storage" true
      (Yojson.Safe.equal (V.to_json prepared) (V.to_json restored));
    let replacement = original authority in
    Alcotest.(check bool) "new preparation observes changed templates" false
      (String.equal (V.prompt replacement) (V.prompt restored));
    let lookup = A.goal_review_lookup authority in
    let result = lookup.dispatch ~name:"tool_read_file"
      ~args:(`Assoc ["file_path", `String "measurement-owner/proof.png"]) in
    match result with
    | Tool_result.Completed {content_blocks=Some blocks; _} ->
      Alcotest.(check bool) "real shared-root Read delivers complete canonical image" true
        (List.exists (function
          | Llm_provider.Types.Image {source=Llm_provider.Types.Base64 data; _} -> Base64.decode_exn data = bytes
          | _ -> false) blocks)
    | Tool_result.Completed {content_blocks=None; _}
    | Tool_result.Failed _ | Tool_result.Deferred _ -> Alcotest.fail (Tool_result.message result)))

let test_other_subject_evidence_and_workspace_refuse () = with_workspace (fun config _root ->
  let goal_id = pending config in
  let admitted = authority config goal_id in
  let prepared = original admitted in
  let other_goal = authority config (pending config) in
  submit_items config goal_id [Evidence.Evidence_note "Changed submission"];
  let changed_submission = authority config goal_id in
  ignore (stored (Goal_store.upsert_goal config ~id:goal_id ~target_value:"101" ()));
  ignore (proof (Workspace_goals.request_current_proof config ~goal_id));
  let changed_criterion = authority config goal_id in
  List.iter (fun other -> Alcotest.(check bool) "different current proof or submission refuses" false
    (V.matches_authority prepared other)) [other_goal; changed_submission; changed_criterion];
  let other_path = Filename.temp_dir "other-goal-workspace-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree other_path) (fun () ->
    let other_config = Workspace.default_config other_path in
    let other_root = Filename.concat (Evidence.project_root_of_base_path other_path)
      Playground_paths.all_playgrounds_prefix in
    Fs_compat.mkdir_p other_root;
    let other = authority other_config (pending ~id:goal_id other_config) in
    Alcotest.(check bool) "another workspace cannot supply the original authority" false
      (V.matches_authority prepared other));
  let child = get (V.successor prepared) in
  Alcotest.(check int) "successor advances only attempt" 1 (V.attempt child);
  let without_attempt = function
    | `Assoc fields -> `Assoc (List.remove_assoc "attempt" fields)
    | _ -> Alcotest.fail "original must be an object" in
  Alcotest.(check bool) "successor retains every semantic field" true
    (Yojson.Safe.equal (without_attempt (V.to_json prepared)) (without_attempt (V.to_json child))))

let test_malformed_original_refuses () = with_workspace (fun config _root ->
  let prepared = original (authority config (pending config)) in
  let fields = match V.to_json prepared with
    | `Assoc fields -> fields | _ -> Alcotest.fail "original must be an object" in
  let reject label json = match V.of_json json with
    | Error _ -> () | Ok _ -> Alcotest.fail label in
  reject "duplicate schema admitted" (`Assoc (("schema", `String V.schema)::fields));
  reject "missing original prompt admitted" (`Assoc (List.remove_assoc "prompt" fields));
  reject "unknown original field admitted" (`Assoc (("operator", `String "invented")::fields));
  let changed_evidence = `List [`Assoc ["kind", `String "note"; "content", `String "changed";
    "untrusted_grant", `Bool true]] in
  reject "unknown nested evidence grant admitted"
    (`Assoc (("submitted_evidence", changed_evidence)::List.remove_assoc "submitted_evidence" fields)))

let reported config goal_id ~value ~source =
  let goal = match Goal_store.find_goal config ~goal_id with
    | Goal_store.Goal_found goal -> goal
    | Goal_absent | Store_unavailable _ -> Alcotest.fail "measurement Goal unavailable" in
  match Goal_measurement.record config ~goal_id
      ~criterion_revision:goal.criterion_revision ~observed_value:value
      ~evidence:("note:" ^ source) ~actor:"measurement-owner" with
  | Ok receipt -> receipt.Goal_measurement.measurement
  | Error error -> Alcotest.fail (Goal_measurement.error_to_string error)

let check_prompt_observation label prepared observation =
  let json = Goal_measurement.observation_to_yojson observation |> Yojson.Safe.to_string in
  Alcotest.(check bool) label true
    (String_util.contains_substring (V.prompt prepared) json)

let test_reported_source_is_captured_without_changing_authority () =
  with_workspace (fun config _root ->
    let goal_id = pending config in
    let first = reported config goal_id ~value:"1/3"
      ~source:"https://example.com/frozen/first-evidence" in
    let admitted = authority config goal_id in
    let prepared = original admitted in
    check_prompt_observation "full current report and source reach original" prepared
      (Ok (Some first));
    let captured = V.to_json prepared in
    let digest = get (V.digest prepared) in
    let second = reported config goal_id ~value:"2/3"
      ~source:"https://example.com/frozen/second-evidence" in
    let fresh = authority config goal_id in
    Alcotest.(check string) "reported context does not change lookup grants"
      (A.goal_review_binding admitted) (A.goal_review_binding fresh);
    Alcotest.(check bool) "new report cannot revoke a retained original" true
      (V.matches_authority prepared fresh);
    check_prompt_observation "new preparation sees newer report" (original fresh)
      (Ok (Some second));
    let restored = get (V.of_json captured) in
    check_prompt_observation "restore keeps original report bytes" restored (Ok (Some first));
    Alcotest.(check string) "later report cannot rerender captured prompt"
      (V.prompt prepared) (V.prompt restored);
    Alcotest.(check string) "later report cannot change original digest"
      digest (get (V.digest restored));
    (* The current schema still admits retained originals whose prompts were
       captured before reported-measurement context existed. *)
    let older = match captured with
      | `Assoc fields -> `Assoc (("prompt", `String "Earlier immutable Goal proof input")
          :: List.remove_assoc "prompt" fields)
      | _ -> Alcotest.fail "original must be an object" in
    let older = get (V.of_json older) in
    Alcotest.(check bool) "earlier prompt schema keeps the same authority" true
      (V.matches_authority older fresh))

let test_only_current_goal_revision_is_reported () = with_workspace (fun config _root ->
  let goal_id = pending config in
  let other_id = pending config in
  ignore (reported config other_id ~value:"other Goal's observation"
    ~source:"https://example.com/other-goal");
  let admitted = authority config goal_id in
  Alcotest.(check bool) "another Goal cannot supply this measurement" true
    (A.goal_review_measurement admitted = Ok None);
  check_prompt_observation "missing report is explicit" (original admitted) (Ok None);
  let stale = reported config goal_id ~value:"old criterion"
    ~source:"https://example.com/old-criterion" in
  ignore (stored (Goal_store.upsert_goal config ~id:goal_id ~target_value:"101" ()));
  ignore (proof (Workspace_goals.request_current_proof config ~goal_id));
  let current = authority config goal_id in
  Alcotest.(check bool) "changed revision has no inherited report" true
    (A.goal_review_measurement current = Ok None);
  Alcotest.(check bool) "the old report is retained in storage, not reused" true
    (match Goal_measurement.load config with
     | Ok rows -> List.exists (fun (row:Goal_measurement.t) -> row.id = stale.id) rows
     | Error _ -> false);
  check_prompt_observation "stale report becomes current-revision missing"
    (original current) (Ok None))

let test_unavailable_report_keeps_original_and_lookup_authority () =
  with_workspace (fun config _root ->
    let goal_id = pending config in
    let row = reported config goal_id ~value:"100"
      ~source:"https://example.com/retained-report" in
    let admitted = authority config goal_id in
    let prepared = original admitted in
    Out_channel.with_open_bin (Goal_measurement.path config)
      (fun out -> output_string out "{\"version\":999,\"measurements\":[]}");
    let unavailable = authority config goal_id in
    let observation = A.goal_review_measurement unavailable in
    (match observation with
     | Error reason -> Alcotest.(check bool) "unavailable reason is preserved" true
         (String.trim reason <> "")
     | Ok _ -> Alcotest.fail "corrupt report store became missing or reported");
    check_prompt_observation "new original explicitly carries lookup unavailability"
      (original unavailable) observation;
    Alcotest.(check string) "unavailable report cannot revoke lookup grants"
      (A.goal_review_binding admitted) (A.goal_review_binding unavailable);
    Alcotest.(check bool) "unavailable report does not invalidate original authority" true
      (V.matches_authority prepared unavailable);
    check_prompt_observation "retained original still has its captured report"
      (get (V.of_json (V.to_json prepared))) (Ok (Some row)))

let test_task_capability_is_submission_bound () = with_workspace (fun config _root ->
  let without_task_id = pending config in
  let without_task = authority config without_task_id in
  let retained_without_task = original without_task in
  let names authority = (A.goal_review_lookup authority).schemas
    |> List.map (fun (schema : Types_core.tool_schema) -> schema.name) in
  Alcotest.(check (list string)) "Task-free authority retains the existing schema surface"
    ["tool_read_file";"masc_web_fetch";"masc_board_post_get";"masc_fusion_status"] (names without_task);
  ignore (Workspace.add_task config ~title:"Exact Task observation" ~priority:1 ~description:"Original Task body");
  let backlog = get (Workspace.read_backlog_r config) in
  let task = List.find (fun (task : Masc_domain.task) -> task.title="Exact Task observation") backlog.tasks in
  let items = Verification_collaboration_evidence.capture ~config
    ~authority:Verification_collaboration_evidence.Goal_workspace ~references:["task:" ^ task.id]
    |> Result.map_error Verification_collaboration_evidence.error_to_string |> get in
  let with_task_id = pending ~items config in
  let with_task = authority config with_task_id in
  let retained_with_task = original with_task in
  Alcotest.(check bool) "explicit Task source adds only its read capability" true
    (names with_task = names without_task @ ["keeper_tasks_list"]);
  Workspace.write_backlog config {backlog with tasks=List.map (fun (row : Masc_domain.task) ->
    if row.id=task.id then {row with title="Changed live Task"} else row) backlog.tasks};
  List.iter (fun (id,prepared) ->
    let restored = get (V.of_json (V.to_json prepared)) in
    Alcotest.(check bool) "retained original matches after unrelated live Task changes" true
      (V.matches_authority restored (authority config id)))
    [without_task_id,retained_without_task;with_task_id,retained_with_task];
  let result = (A.goal_review_lookup (authority config with_task_id)).dispatch
    ~name:"keeper_tasks_list" ~args:(`Assoc ["task_ids",`List [`String task.id]]) in
  match result with
  | Tool_result.Completed _ ->
    let source = Tool_result.message result |> Yojson.Safe.from_string in
    Alcotest.(check bool) "restored authority reads the submitted original Task" true
      (Yojson.Safe.Util.member "task" source = Masc_domain.task_to_yojson task)
  | Tool_result.Failed _ | Tool_result.Deferred _ -> Alcotest.fail (Tool_result.message result))

let () = Alcotest.run "goal verifier original" ["host preparation", [
  Alcotest.test_case "Task capability follows submitted evidence and retained authority" `Quick test_task_capability_is_submission_bound;
  Alcotest.test_case "fresh Goal proof needs no Keeper or manual shared root" `Quick test_fresh_goal_without_keeper_or_manual_playground;
  Alcotest.test_case "retained prompt and actual shared-root visual lookup" `Quick test_stored_goal_preparation_and_actual_visual_lookup;
  Alcotest.test_case "exact subject, evidence and workspace authority" `Quick test_other_subject_evidence_and_workspace_refuse;
  Alcotest.test_case "malformed immutable input refuses" `Quick test_malformed_original_refuses;
  Alcotest.test_case "reported source and immutable authority" `Quick test_reported_source_is_captured_without_changing_authority;
  Alcotest.test_case "exact Goal and criterion measurement" `Quick test_only_current_goal_revision_is_reported;
  Alcotest.test_case "unavailable report preserves original authority" `Quick test_unavailable_report_keeps_original_and_lookup_authority]]
