module AR = Masc.Task.Anti_rationalization
module V = Masc.Verifier_review_original
module O = Masc.Verifier_review_owner
module W = Masc.Verifier_review_worker
module A = Masc.Verification_authority_tools
module Store = Workspace_verification_store
module Workspace = Masc.Workspace
module Verification = Masc.Verification
let get = function Ok x -> x | Error detail -> Alcotest.fail detail
let retained = function Ok x -> x | Error _ -> Alcotest.fail "original retain failed"
let loaded = function Ok x -> x | Error _ -> Alcotest.fail "original load failed"
let installation_id = "masc.verifier"
let package_id = "masc.verifier.review"
let verification_id = "vrf-retained-review"
let producer = "review-fixture"
let task_id = "task-001"
let image : AR.evidence_image =
  { image_reference="artifact:shot.png";image_sha256="abc";image_bytes=1;
    image_media_type="image/png";image_body_base64="aGk=" }
let request : AR.review_request =
  {task_title="T";task_description="D";completion_notes="N";agent_name=producer;
   task_id;evidence_refs=[];evidence_images=[image]}
let question : AR.verdict_question =
  {completion_contract=None;required_evidence=[];evidence_posture=AR.Note_only;few_shot_block=""}

let with_workspace_runtime f =
  let base_path = Filename.temp_dir "verifier-worker-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.clear_fs ();Fs_compat.remove_tree base_path;
    Config_dir_resolver.reset ()) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key
    (Some (Filename.concat base_path ".masc/config")) (fun () ->
    Config_dir_resolver.reset ();
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Workspace_core.default_config base_path in
      let store = Masc.Lane_addon_store.create ~root:(Filename.concat (Workspace_core.masc_dir config) "lane-addons") in
      f config store (Eio.Stdenv.clock env)))))

let with_workspace f = with_workspace_runtime (fun config store _clock -> f config store)

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
let domain_notes result =
  Masc.Completion_authority_agent.For_testing.review_notes
    ~request:{Verification.id=verification_id;task_id;worker=producer;created_at=1.;output=`Null;criteria=[]}
    ~evidence_access:(Store.Evidence_available {
      request={id=verification_id;task_id;worker=producer;created_at=1.};items=[]})
    ~unread_images:[] ~result
    ~authority:(Masc_domain.System_llm_agent {
      agent_run_id=Masc.Completion_authority_agent.For_testing.authority_actor})

let run ?(package=package_id) store authority attempt =
  W.run_attempt ~prepare_notes:domain_notes ~store ~verification_id ~attempt ~installation_id ~package_id:package
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
  let system_before=Prompt_registry.resolve_prompt Prompt_names.verification_system in
  let restore name before = match before.Prompt_registry.override_value with
    | None -> Prompt_registry.clear_prompt_override name
    | Some text -> ignore (get (Prompt_registry.set_override name text)) in
  Fun.protect ~finally:(fun () -> restore Prompt_names.verification before;
    restore Prompt_names.verification_system system_before) (fun () ->
    get (Prompt_registry.set_override Prompt_names.verification (before.effective ^ "\nChanged after retention."));
    get (Prompt_registry.set_override Prompt_names.verification_system (system_before.effective ^ "\nSystem changed after retention."));
    let root = Keeper_sandbox_config.host_root_abs_of_producer
      ~base_path:(Store.project_root_of_base_path config.Workspace.base_path) ~agent_name:producer in
    Fs_compat.mkdir_p root;
    Out_channel.with_open_bin (Filename.concat root "receipt.txt") (fun out -> output_string out "retained evidence");
    let calls = ref 0 in
    with_reviewer (fun ~base_path ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
        ?system_prompt ?goal_blocks ~report_tool_schema:_ ~lookup ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls;
      Alcotest.(check string) "original workspace reaches reviewer" config.base_path base_path;
      Alcotest.(check string) "exact stored prompt reaches reviewer" (V.system_prompt_text first) prompt;
      Alcotest.(check (option string)) "exact original system instructions reach reviewer"
        (Some (V.system_instructions first)) system_prompt;
      let expected = Agent_core.Types.image_block ~media_type:image.image_media_type
        ~data:image.image_body_base64 () in
      Alcotest.(check bool) "original media reaches reviewer" true (goal_blocks=Some [Agent_core.Types.text_block prompt;expected]);
      (match lookup.AR.dispatch ~name:"tool_read_file" ~args:(`Assoc ["file_path",`String "receipt.txt"]) with
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
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
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

let test_known_retry_preserves_frozen_original () = with_workspace (fun config store ->
  let a=authority config in
  let next ()=loaded (O.next_attempt ~store ~verification_id ~installation_id ~package_id) in
  let first=original a (next ()) in
  retain store first;
  Alcotest.(check int) "wake without terminal retry keeps original" 0 (next ());
  let calls=ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error () ->
    incr calls;
    Alcotest.(check string) "retry preserves exact prompt" (V.system_prompt_text first) prompt;
    if !calls=1 then (
      let error=Agent_core.Error.Api (Agent_core.Error.Retry.RateLimited
        {retry_after=None;message="definite complete HTTP refusal"}) in
      on_runtime_attempt_error ~runtime_id:"fixture-reviewer" ~attempt:0
        ~dispatch:Runtime_attempt_dispatch.Dispatched error; Error error)
    else Ok {AR.selected_runtime_id="fixture-reviewer";verdict=Some (AR.Approve "retry checked")}) (fun () ->
    (match run store a 0 with Ok {AR.verdict=None;retryable_runtimes=_::_;_} -> ()
     | Ok _ | Error _ -> Alcotest.fail "known transient did not retain retry authority");
    let retry=next () in
    Alcotest.(check int) "explicit terminal transition produces one linked successor" 1 retry;
    Alcotest.(check int) "another wake reuses the same successor" retry (next ());
    let second=loaded (O.load_for_destination ~store ~verification_id ~attempt:retry ~installation_id ~package_id) in
    Alcotest.(check bool) "whole successor differs only in identity" true
      (V.to_json second=V.to_json (get (V.successor first)));
    (match run store a retry with Ok {AR.verdict=Some (Approve "retry checked");_} -> ()
     | Ok _ | Error _ -> Alcotest.fail "safe linked retry failed");
    ignore (loaded (run store a retry));
    Alcotest.(check int) "restored judgment never invokes a second model" 2 !calls;
    Alcotest.(check int) "judgment is not another retry authorization" retry (next ())))

let test_unknown_and_cancelled_never_redispatch () = with_workspace (fun config store ->
  let a=authority config in retain store (original a 0);
  let calls=ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error () ->
    incr calls;
    let error=Agent_core.Error.Api (Agent_core.Error.Retry.NetworkError {message="reply lost";kind=Llm_provider.Http_client.Connection_reset}) in
    on_runtime_attempt_error ~runtime_id:"fixture-reviewer" ~attempt:0
      ~dispatch:Runtime_attempt_dispatch.Dispatched error;
    Error error) (fun () ->
      let slots=Atomic.get Workspace_hooks.get_verifier_exact_lane_slots_fn in
      Fun.protect ~finally:(fun () -> Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn slots) (fun () ->
        Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
          (fun () -> Ok ["fixture-reviewer",Types_core.Catalog_slot;"must-not-run",Types_core.Catalog_slot]);
        (match run store a 0 with Error (W.Execution_pending _) -> ()
         | Ok _ | Error _ -> Alcotest.fail "lost response was treated as known completion");
        let restored=loaded (O.next_attempt ~store ~verification_id ~installation_id ~package_id) in
        Alcotest.(check int) "unknown keeps original identity" 0 restored;
        (match run store a restored with Error (W.Execution_pending _) -> ()
         | Ok _ | Error _ -> Alcotest.fail "unknown original replayed");
        Alcotest.(check int) "neither fallback nor restart dispatches" 1 !calls)));
  with_workspace (fun config store ->
    let a=authority config in retain store (original a 0);
    let calls=ref 0 in
    with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
        ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls;
      raise (Eio.Cancel.Cancelled Exit)) (fun () ->
        (try ignore (run store a 0);Alcotest.fail "cancellation swallowed"
         with Eio.Cancel.Cancelled _ -> ());
        (match run store a 0 with Error (W.Execution_pending _) -> ()
         | Ok _ | Error _ -> Alcotest.fail "cancelled original replayed");
        Alcotest.(check int) "cancelled provider called once" 1 !calls))

let task_in_backlog config =
  let backlog=get (Workspace_backlog.read_backlog_r config) in
  match List.find_opt (fun (task:Masc_domain.task) -> task.id=task_id) backlog.tasks with
  | Some task -> task | None -> Alcotest.fail "domain fixture task missing"

let prepare_domain config =
  ignore (Workspace_core.init config ~agent_name:None);
  ignore (Workspace_core.add_task config ~title:"T" ~description:"D" ~priority:1);
  let backlog=get (Workspace_backlog.read_backlog_r config) in
  Workspace_core.write_backlog config {backlog with tasks=List.map (fun (task:Masc_domain.task) ->
    {task with task_status=Masc_domain.AwaitingVerification {assignee=producer;
      started_at="2026-10-23T00:00:00Z";submitted_at="2026-10-23T00:01:00Z";verification_id}}) backlog.tasks};
  task_in_backlog config

let test_actual_host_commit_restart () = with_workspace (fun config store ->
  let task=prepare_domain config in
  let a=authority config in let first=original a 0 in retain store first;
  let calls=ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls;Ok {AR.selected_runtime_id="fixture-reviewer";verdict=Some (AR.Approve "checked")}) (fun () ->
    let result=loaded (run store a 0) in
    let notes=domain_notes result in
    get (Masc.Completion_authority_agent.For_testing.commit_original ~config ~task ~store ~attempt:0
      ~installation_id ~package_id ~verification_id ~notes);
    ignore (loaded (run store a 0));
    get (Masc.Completion_authority_agent.For_testing.commit_original ~config ~task:(task_in_backlog config)
      ~store ~attempt:0 ~installation_id ~package_id ~verification_id ~notes:"new notes must not replace original");
    Alcotest.(check int) "success and full restart use one model" 1 !calls;
    match (task_in_backlog config).Masc_domain.task_status with
    | Done {notes=Some saved;_} -> Alcotest.(check string) "domain retained exact original notes" notes saved
    | Todo | Claimed _ | InProgress _ | AwaitingVerification _ | Done _ | Cancelled _ ->
      Alcotest.fail "actual host did not confirm the verdict"))

let test_actual_host_commit_cancel_after_domain_write () = with_workspace (fun config store ->
  let task=prepare_domain config in let a=authority config in retain store (original a 0);
  let calls=ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls;Ok {AR.selected_runtime_id="fixture-reviewer";verdict=Some (AR.Approve "checked")}) (fun () ->
    let result=loaded (run store a 0) in let notes=domain_notes result in
    let hook=Atomic.get Workspace_hooks.task_terminal_committed_fn in
    Fun.protect ~finally:(fun () -> Atomic.set Workspace_hooks.task_terminal_committed_fn hook) (fun () ->
      Atomic.set Workspace_hooks.task_terminal_committed_fn
        (fun _ ~actor:_ ~task_id:_ -> raise (Eio.Cancel.Cancelled Exit));
      (try
         ignore (Masc.Completion_authority_agent.For_testing.commit_original ~config ~task ~store ~attempt:0
           ~installation_id ~package_id ~verification_id ~notes);
         Alcotest.fail "post-write cancellation did not propagate"
       with Eio.Cancel.Cancelled _ -> ()));
    let pending=loaded (O.pending_commits ~store ~installation_id ~package_id) in
    Alcotest.(check int) "boot finds pending commit after Task left awaiting" 1 (List.length pending);
    let restarted=task_in_backlog config in
    (match restarted.Masc_domain.task_status with Done _ -> ()
     | Todo | Claimed _ | InProgress _ | AwaitingVerification _ | Cancelled _ -> Alcotest.fail "domain commit not applied");
    get (Masc.Completion_authority_agent.For_testing.commit_original ~config ~task:restarted ~store ~attempt:0
      ~installation_id ~package_id ~verification_id ~notes:"ignored new note");
    Alcotest.(check int) "boot confirms original domain receipt" 0
      (List.length (loaded (O.pending_commits ~store ~installation_id ~package_id)));
    Alcotest.(check int) "domain cancellation does not call another model" 1 !calls))

let test_judgment_recovery_precedes_actual_preparation () =
  with_workspace_runtime (fun config store clock ->
    Eio.Switch.run (fun sw ->
      let task=prepare_domain config in
      let a=authority config in let first=original a 0 in
      let installation_id="masc.completion-authority" in
      let package_id="masc.completion-authority.review" in
      retained (O.retain ~store ~verification_id ~attempt:0 ~installation_id ~package_id first);
      let calls=ref 0 in
      with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
          ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
        incr calls;Ok {AR.selected_runtime_id="fixture-reviewer";verdict=Some (AR.Approve "checked")}) (fun () ->
        let result=loaded (W.run_attempt ~prepare_notes:domain_notes ~store ~verification_id ~attempt:0
          ~installation_id ~package_id ~authority:a ~provider_rest:(fun _ -> AR.No_stated_rest) ()) in
        let saved=loaded (O.load_retained ~store ~verification_id ~attempt:0 ~installation_id ~package_id) in
        (match Masc.Lane_addon_request_progress.phase (O.progress saved) with
         | Judged _ -> ()
         | Captured | Admission_wait _ | Dispatch_pending _ | Committing _ | Commit_unknown _ | Finished _
         | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> Alcotest.fail "fixture crossed commit boundary too early");
        (* This request was deliberately never published to Verification: real
           prepare_review would fail before it could rebuild a remote layout. *)
        (match Verification.load_request config.Workspace_core.base_path verification_id with
         | Error _ -> () | Ok _ -> Alcotest.fail "preparation refusal fixture is not real");
        get (Masc.Completion_authority_agent.For_testing.process_original_once
          ~config ~sw ~clock ~task ~assignee:producer ~verification_id);
        Alcotest.(check int) "actual production restart never reaches another provider" 1 !calls;
        (match (task_in_backlog config).Masc_domain.task_status with
         | Done {notes=Some notes;_} -> Alcotest.(check string) "commit uses exact retained judgment notes"
             (domain_notes result) notes
         | Todo | Claimed _ | InProgress _ | AwaitingVerification _ | Done _ | Cancelled _ ->
           Alcotest.fail "production host did not recover Judged without preparation"))))

let test_commit_unknown_recovers_exact_original () = with_workspace (fun config store ->
  let a=authority config in let first=original a 0 in retain store first;
  let calls=ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls;Ok {AR.selected_runtime_id="fixture-reviewer";verdict=Some (AR.Reject "repair")}) (fun () ->
    let result=loaded (run store a 0) in
    let digest=get (V.digest first) in
    let before=`Assoc ["verification_id",`String verification_id;"phase",`String "awaiting"] in
    let after=`Assoc ["original_digest",`String digest;"review",O.result_to_json result;
      "notes",`String (domain_notes result);"verification_id",`String verification_id;"phase",`String "rejected"] in
    let canonical json=get (Masc.Lane_addon_action.canonical json) in
    let before=canonical before and after=canonical after in
    let domain=ref before and commits=ref 0 in
    let observe (_:Masc.Lane_addon_request_progress.change)=Ok !domain in
    let apply (_:Masc.Lane_addon_request_progress.change)=
      incr commits;domain:=after;Error "reply lost after domain commit" in
    (match W.commit_attempt ~store ~verification_id ~attempt:0 ~installation_id ~package_id
      ~change:{Masc.Lane_addon_request_progress.before;after} ~observe ~apply with
     | Error (W.Execution_pending _) -> () | Ok _ | Error _ -> Alcotest.fail "unknown commit not retained");
    ignore (loaded (run store a 0));
    get (W.commit_attempt ~store ~verification_id ~attempt:0 ~installation_id ~package_id
      ~change:{Masc.Lane_addon_request_progress.before=`Null;after=`Null}
      ~observe ~apply |> Result.map_error (fun _ -> "commit recovery failed"));
    Alcotest.(check int) "lost commit reply causes no duplicate domain effect" 1 !commits;
    Alcotest.(check int) "lost commit reply causes no new provider" 1 !calls))

let test_actual_inner_walk_respects_retained_disposition () =
  let exercise retained_request = with_workspace (fun config store ->
    let a=authority config in let first=original a 0 in retain store first;
    let calls=ref [] in
    with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime ~candidate_kind:_ ~prompt:_
        ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
        ~attempt_continuation ~on_runtime_attempt_error () ->
      Masc.Keeper_turn_driver.For_testing.attempt_runtime_candidates
        ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
        ~runtime_id:evaluator_runtime ~runtime_id_of:Fun.id
        ~quota_scope_of:(fun _ -> None)
        ~candidate_backpressure_of:(fun _ -> None) ~candidate_dispatchable:(fun _ -> true)
        ~read_usage_after_account_refusal:(fun _ -> ())
        ~attempt_continuation ~on_attempt_error:on_runtime_attempt_error
        ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
        ~run_attempt:(fun ~idx ~runtime_id _candidate ->
          calls:=runtime_id::!calls;
          let result=if idx=0 then Error (Agent_core.Error.Api (Agent_core.Error.Retry.NetworkError
            {message="lost after dispatch";kind=Llm_provider.Http_client.Connection_reset}))
          else Ok {AR.selected_runtime_id=runtime_id;verdict=Some (AR.Approve "checked")} in
          result,None,Masc.Keeper_provider_attempt_effect.No_effect_observed,
          Masc.Keeper_attempt_dispatch.Dispatched)
        ["first-provider";"second-provider"]) (fun () ->
      if retained_request then (
        (match run store a 0 with Error (W.Execution_pending _) -> ()
         | Ok _ | Error _ -> Alcotest.fail "retained actual inner walk lost uncertainty");
        Alcotest.(check (list string)) "actual inner admission blocks the second provider"
          ["first-provider"] (List.rev !calls);
        (match run store a 0 with Error (W.Execution_pending _) -> ()
         | Ok _ | Error _ -> Alcotest.fail "retained inner unknown redispatched on restart");
        Alcotest.(check int) "restart does not enter any provider" 1 (List.length !calls))
      else (
        let result=AR.review ~question ~lookup:(A.task_review_lookup a) ~lookup_root:(A.task_review_root a)
          ~provider_rest:(fun _ -> AR.No_stated_rest) ~base_path:config.Workspace_core.base_path request in
        Alcotest.(check (list string)) "ordinary consumer keeps existing inner walk admission"
          ["first-provider";"second-provider"] (List.rev !calls);
        match result.AR.verdict with Some (Approve "checked") -> ()
        | Some (Approve _ | Reject _) | None -> Alcotest.fail "ordinary control did not reach its existing fallback"))) in
  exercise true;exercise false

let test_pre_admission_configuration_reenters_same_original () = with_workspace (fun config store ->
  let a=authority config in let first=original a 0 in retain store first;
  let calls=ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
      ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls;
    Alcotest.(check string) "re-admission preserves original prompt" (V.system_prompt_text first) prompt;
    Ok {AR.selected_runtime_id="fixture-reviewer";verdict=Some (AR.Approve "admitted")}) (fun () ->
    Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
      (fun () -> Error "fixture typed slot admission is unavailable");
    (match run store a 0 with Ok {AR.verdict=None;_} -> ()
     | Ok _ | Error _ -> Alcotest.fail "pre-admission refusal did not remain recoverable");
    Alcotest.(check int) "slot refusal invokes no reviewer RPC" 0 !calls;
    let retained=loaded (O.load_retained ~store ~verification_id ~attempt:0 ~installation_id ~package_id) in
    (match Masc.Lane_addon_request_progress.phase (O.progress retained) with
     | Admission_wait evidence ->
       Alcotest.(check bool) "actual admission fact retained" true
         (Yojson.Safe.Util.member "observations" evidence <> `Null)
     | Captured | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _ | Finished _
     | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> Alcotest.fail "pre-admission became execution terminal");
    Alcotest.(check int) "configuration repair cannot allocate a successor" 0
      (loaded (O.next_attempt ~store ~verification_id ~installation_id ~package_id));
    Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
      (fun () -> Ok ["fixture-reviewer",Types_core.Catalog_slot]);
    (match run store a 0 with Ok {AR.verdict=Some (Approve "admitted");_} -> ()
     | Ok _ | Error _ -> Alcotest.fail "fixed configuration could not re-admit exact original");
    Alcotest.(check int) "one provider after real pre-admission repair" 1 !calls;
    Alcotest.(check int) "same original owns the answer" 0
      (loaded (O.next_attempt ~store ~verification_id ~installation_id ~package_id))))

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
    Alcotest.test_case "retry keeps both immutable originals" `Quick test_known_retry_preserves_frozen_original;
    Alcotest.test_case "unknown and cancellation never redispatch" `Quick test_unknown_and_cancelled_never_redispatch;
    Alcotest.test_case "actual host commit and restart" `Quick test_actual_host_commit_restart;
    Alcotest.test_case "actual host recovers cancellation after domain write" `Quick test_actual_host_commit_cancel_after_domain_write;
    Alcotest.test_case "Judged recovery precedes actual preparation" `Quick test_judgment_recovery_precedes_actual_preparation;
    Alcotest.test_case "commit unknown recovers original" `Quick test_commit_unknown_recovers_exact_original;
    Alcotest.test_case "actual inner walk respects retained disposition" `Quick test_actual_inner_walk_respects_retained_disposition;
    Alcotest.test_case "pre-admission configuration repair reuses original" `Quick test_pre_admission_configuration_reenters_same_original;
    Alcotest.test_case "invalid inventory refuses allocation" `Quick test_bad_inventory_is_not_partial_authority]]
