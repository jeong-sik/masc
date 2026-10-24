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

let with_workspace f =
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
      let root = Filename.concat
        (Evidence.project_root_of_base_path path) (Playground_paths.bundle_root "measurement-owner") in
      Fs_compat.mkdir_p root;
      Prompt_registry.set_markdown_dir
        (Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts");
      f config root))))

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
    bytes=String.length bytes; sha256=Digestif.SHA256.(digest_string bytes |> to_hex);
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
          | Llm_provider.Types.Image {data; _} -> Base64.decode_exn data = bytes
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

let () = Alcotest.run "goal verifier original" ["host preparation", [
  Alcotest.test_case "retained prompt and actual shared-root visual lookup" `Quick test_stored_goal_preparation_and_actual_visual_lookup;
  Alcotest.test_case "exact subject, evidence and workspace authority" `Quick test_other_subject_evidence_and_workspace_refuse;
  Alcotest.test_case "malformed immutable input refuses" `Quick test_malformed_original_refuses]]
