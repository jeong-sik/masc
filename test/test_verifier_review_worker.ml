module AR = Masc.Task.Anti_rationalization
module V = Masc.Verifier_review_original
module O = Masc.Verifier_review_owner
module W = Masc.Verifier_review_worker
module A = Masc.Verification_authority_tools
module Store = Masc.Workspace_verification_store
let get = function Ok x -> x | Error detail -> Alcotest.fail detail
let retained = function Ok x -> x | Error _ -> Alcotest.fail "original retain failed"
let loaded = function Ok x -> x | Error _ -> Alcotest.fail "original load failed"
let installation_id = "masc.verifier"
let package_id = "masc.verifier.review"
let verification_id = "vrf-retained-review"
let producer = "review-fixture"
let task_id = "task-review-fixture"
let image : AR.evidence_image =
  { image_reference="artifact:shot.png";image_sha256="abc";image_bytes=1;
    image_media_type="image/png";image_body_base64="aGk=" }
let request : AR.review_request =
  {task_title="T";task_description="D";completion_notes="N";agent_name=producer;
   task_id;evidence_refs=[];evidence_images=[image]}
let question : AR.verdict_question =
  {completion_contract=None;required_evidence=[];evidence_posture=AR.Note_only;few_shot_block=""}

let with_workspace f =
  let base_path = Filename.temp_dir "verifier-worker-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.clear_fs ();Fs_compat.remove_tree base_path;
    Masc.Config_dir_resolver.reset ()) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key
    (Some (Filename.concat base_path ".masc/config")) (fun () ->
    Masc.Config_dir_resolver.reset ();
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Workspace_core.default_config base_path in
      let store = Masc.Lane_addon_store.create ~root:(Filename.concat base_path "request-ownership") in
      f config store))))

let authority ?(worker=producer) ?(items=[]) config =
  let evidence_access = Store.Evidence_available {
    request={id=verification_id;task_id;worker;created_at=1.};items} in
  get (A.create_task_review ~config ~verification_id ~task_id ~producer:worker ~evidence_access)

let original ?(question=question) authority attempt =
  get (V.prepare ~verification_id ~attempt ~question
    ~lookup_root:(A.task_review_root authority)
    ~lookup_binding:(A.task_review_binding authority)
    ~lookup_schemas:(List.map (fun (s:Types_core.tool_schema) -> s.name)
      (A.schemas (A.task_review_tools authority))) request)

let retain store original = retained (O.retain ~store ~verification_id
  ~attempt:(V.attempt original) ~installation_id ~package_id original)
let run ?(package=package_id) store authority attempt =
  W.run_attempt ~store ~verification_id ~attempt ~installation_id ~package_id:package
    ~authority ~provider_rest:(fun _ -> AR.No_stated_rest) ()

let with_reviewer reviewer f =
  let previous = Atomic.get AR.run_llm_reviewer_fn in
  let slots = Atomic.get Workspace_hooks.get_verifier_exact_lane_slots_fn in
  Fun.protect ~finally:(fun () -> Atomic.set AR.run_llm_reviewer_fn previous;
    Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn slots) (fun () ->
    Atomic.set AR.run_llm_reviewer_fn reviewer;
    Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
      (fun () -> Ok ["fixture-reviewer",Types_core.Catalog_slot]); f ())

let test_frozen_prompt_media_and_lookup () = with_workspace (fun config store ->
  let a = authority config in
  let first = original a 0 in
  retain store first;
  let before = Prompt_registry.resolve_prompt Prompt_names.verification in
  Fun.protect ~finally:(fun () -> match before.override_value with
    | None -> Prompt_registry.clear_prompt_override Prompt_names.verification
    | Some text -> ignore (get (Prompt_registry.set_override Prompt_names.verification text))) (fun () ->
    get (Prompt_registry.set_override Prompt_names.verification (before.effective ^ "\nChanged after retention."));
    let root = Masc.Keeper_sandbox_config.host_root_abs_of_producer
      ~base_path:(Store.project_root_of_base_path config.Workspace.base_path) ~agent_name:producer in
    Fs_compat.mkdir_p root;
    Out_channel.with_open_bin (Filename.concat root "receipt.txt") (fun out -> output_string out "retained evidence");
    let calls = ref 0 in
    with_reviewer (fun ~base_path ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
        ?goal_blocks ~report_tool_schema:_ ~lookup ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
      incr calls;
      Alcotest.(check string) "original workspace reaches reviewer" config.base_path base_path;
      Alcotest.(check string) "exact stored prompt reaches reviewer" (V.system_prompt_text first) prompt;
      let expected = Agent_core.Types.image_block ~media_type:image.image_media_type
        ~data:image.image_body_base64 () in
      Alcotest.(check bool) "original media reaches reviewer" true (goal_blocks=Some [Agent_core.Types.text_block prompt;expected]);
      (match lookup.AR.dispatch ~name:"tool_read_file" ~args:(`Assoc ["path",`String "receipt.txt"]) with
       | Tool_result.Completed payload ->
         Alcotest.(check bool) "successful owned lookup retains shared evidence projection" true
           (Yojson.Safe.Util.member "evidence_lookup_succeeded" payload.data = `Bool true)
       | Tool_result.Failed _ | Tool_result.Deferred _ -> Alcotest.fail "owned evidence read failed");
      Ok {AR.selected_runtime_id="fixture-reviewer";verdict=Some (AR.Approve "checked")})
      (fun () -> match run store a 0 with
       | Ok {AR.verdict=Some (Approve "checked");_} -> Alcotest.(check int) "one actual reviewer dispatch" 1 !calls
       | Ok _ | Error _ -> Alcotest.fail "retained review did not return the structured verdict")))

let test_refusals_dispatch_nothing () = with_workspace (fun config store ->
  let a = authority config in
  let calls = ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
      incr calls;Alcotest.fail "refused review dispatched") (fun () ->
    (match run store a 0 with Error W.Original_not_found -> () | _ -> Alcotest.fail "missing original accepted");
    retain store (original a 0);
    (match run ~package:"another-package" store a 0 with
     | Error (W.Original_corrupt _) -> () | _ -> Alcotest.fail "different destination accepted");
    let changed = authority ~items:[Store.Evidence_note "different captured evidence"] config in
    (match run store changed 0 with
     | Error (W.Grants_mismatch _) -> () | _ -> Alcotest.fail "changed snapshot accepted");
    let another = authority ~worker:"another-producer" config in
    (match run store another 0 with
     | Error (W.Grants_mismatch _) -> () | _ -> Alcotest.fail "another producer accepted");
    with_workspace (fun other_config _ ->
      let elsewhere = authority other_config in
      match run store elsewhere 0 with
      | Error (W.Grants_mismatch _) -> () | _ -> Alcotest.fail "another workspace accepted");
    Alcotest.(check int) "no refused path dispatches a reviewer" 0 !calls))

let test_retry_allocates_another_original () = with_workspace (fun config store ->
  let a = authority config in
  let next () = loaded (O.next_attempt ~store ~verification_id ~installation_id ~package_id) in
  let attempt = next () in
  let first = original a attempt in
  retain store first;
  let calls = ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
    incr calls;
    if !calls = 1 then Error (Agent_core.Error.Api (Agent_core.Error.Retry.RateLimited
      {retry_after=None;message="transient fixture failure"}))
    else Ok {AR.selected_runtime_id="fixture-reviewer";verdict=Some (AR.Approve "retry checked")}) (fun () ->
    (match run store a attempt with
     | Ok {AR.verdict=None;retryable_runtimes=_::_;_} -> ()
     | Ok _ | Error _ -> Alcotest.fail "transient first attempt did not request retry");
    let retry = next () in
    Alcotest.(check bool) "retry gets a fresh durable identity" true (retry>attempt);
    let second = original ~question:{question with few_shot_block="new calibration"} a retry in
    retain store second;
    (match run store a retry with
     | Ok {AR.verdict=Some (Approve "retry checked");_} -> ()
     | Ok _ | Error _ -> Alcotest.fail "retry failed to run its new retained original");
    let old = loaded (O.load_for_destination ~store ~verification_id ~attempt ~installation_id ~package_id) in
    Alcotest.(check string) "new calibration does not overwrite prior input"
      (V.system_prompt_text first) (V.system_prompt_text old);
    Alcotest.(check bool) "retry stores its own new question" true
      (V.question second <> V.question old);
    Alcotest.(check int) "one failed and one successful dispatch" 2 !calls;
    let third = next () in
    Alcotest.(check bool) "later retry also advances" true (third>retry)))

let test_bad_inventory_is_not_partial_authority () = with_workspace (fun _config store ->
  get (Masc.Lane_addon_tool_request_owner.retain ~store ~scope:"verifier-reviews"
    ~request_id:"malformed-inventory" ~installation_id ~package_id ~tool:"verifier_review"
    ~summary:(`Assoc ["unexpected",`Bool true]) ~request:(`Assoc ["body",`String "unrelated"])
    |> Result.map_error Masc.Lane_addon_tool_request_owner.error_to_string);
  match O.next_attempt ~store ~verification_id ~installation_id ~package_id with
  | Error (O.Corrupt_original _) -> () | _ -> Alcotest.fail "malformed inventory authorized a fresh attempt")

let () =
  let prompts = Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts" in
  Prompt_registry.set_markdown_dir prompts;
  Prompt_registry.load_prompts_from_directory prompts;
  Masc_test_deps.init_unified_tool_registry ();
  Alcotest.run "retained verifier execution" ["execution",[
    Alcotest.test_case "frozen prompt, media, lookup and verdict" `Quick test_frozen_prompt_media_and_lookup;
    Alcotest.test_case "missing and changed authority refuse before dispatch" `Quick test_refusals_dispatch_nothing;
    Alcotest.test_case "retry keeps both immutable originals" `Quick test_retry_allocates_another_original;
    Alcotest.test_case "invalid inventory refuses allocation" `Quick test_bad_inventory_is_not_partial_authority]]
