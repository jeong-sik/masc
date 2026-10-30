module AR = Masc.Task.Anti_rationalization
module V = Masc.Verifier_review_original
module O = Masc.Verifier_review_owner
module W = Masc.Verifier_review_worker
module A = Masc.Verification_authority_tools
module Store = Workspace_verification_store
module Workspace = Masc.Workspace
module Verification = Masc.Verification
module R = Masc.Verification_run_registry
module P = Masc.Lane_addon_request_progress
module Publication = Masc.Verifier_review_publication
module Host = Masc.Completion_authority_agent.For_testing
let host_installation = "masc.completion-authority"
let host_package = "masc.completion-authority.review"
let get = function Ok x -> x | Error detail -> Alcotest.fail detail
let retained = function Ok x -> x | Error _ -> Alcotest.fail "original retain failed"
let expect_superseded ~authority = function
  | Error detail -> Alcotest.(check string) "private helper preserves superseded refusal"
      ("original superseded by " ^ authority) detail
  | Ok () -> Alcotest.fail "superseded original was reported as committed"
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

let original ?(question=question) ?lookup_root authority attempt =
  get (V.prepare ~generator_runtime:None ~verification_id ~attempt ~question
    ~lookup_root:(match lookup_root with Some root -> root | None -> A.task_review_root authority)
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
    ~base_path:(A.task_review_base_path authority) ~prepare_authority:(fun () -> Ok authority) ~provider_rest:(fun _ -> AR.No_stated_rest) ()
  |> Result.map snd

let pending ~store ~installation_id ~package_id =
  O.pending_commits ~terminal_pending:Publication.needs_publication
    ~selection:O.All_verifications
    ~store ~installation_id ~package_id

let execution_observer ~clock ~started_at ~before ~original result =
  let outcome=match result.AR.verdict with
    | Some (Approve reason) -> R.Approved {reason}
    | Some (Reject reason) -> R.Rejected {reason}
    | None -> Alcotest.fail "observed fixture must produce a verdict" in
  let request=V.review_request original in
  let expected : R.run = {
    verification_id=V.verification_id original;task_id=request.task_id;producer=request.agent_name;
    authority_kind=Masc_domain.completion_authority_kind Publication.authority;
    authority_actor=Masc_domain.completion_authority_actor Publication.authority;
    started_at;status=R.Completed {outcome;evaluator_runtime=Some result.evaluator_runtime;
      elapsed_s=Eio.Time.now clock -. started_at;tools=[]}} in
  Publication.execution_receipt ~original ~result ~before ~expected

let run_observed ?on_verdict ~clock ~task ~store ~installation_id ~package_id original authority =
  let started_at=Eio.Time.now clock in
  W.run_attempt ?on_verdict ~prepare_notes:domain_notes
    ~prepare_observer_registration:(execution_observer ~clock ~started_at
      ~before:task.Masc_domain.task_status ~original)
    ~store ~verification_id:(V.verification_id original) ~attempt:(V.attempt original)
    ~installation_id ~package_id ~base_path:(A.task_review_base_path authority) ~prepare_authority:(fun () -> Ok authority) ~provider_rest:(fun _ -> AR.No_stated_rest) ()
  |> Result.map snd

let with_reviewer reviewer f =
  let previous = Atomic.get AR.run_llm_reviewer_fn in
  let slots = Atomic.get Workspace_hooks.get_verifier_exact_lane_slots_fn in
  Fun.protect ~finally:(fun () -> Atomic.set AR.run_llm_reviewer_fn previous;
    Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn slots) (fun () ->
    Atomic.set AR.run_llm_reviewer_fn reviewer;
    Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
      (fun () -> Ok ["fixture-reviewer",Types_core.Catalog_slot]); f ())

let test_worker_returns_its_loaded_original () = with_workspace (fun config store ->
  let a=authority config in
  let first=original a 0 in
  retain store first;
  let earlier=loaded (O.load_for_destination ~store ~verification_id ~attempt:0 ~installation_id ~package_id) in
  let second=get (V.prepare ~generator_runtime:None ~verification_id ~attempt:0 ~question
    ~lookup_root:(A.task_review_root a) ~lookup_binding:(A.task_review_binding a)
    ~lookup_schemas:(List.map (fun (schema:Types_core.tool_schema) -> schema.name)
      (A.schemas (A.task_review_tools a))) {request with task_title="replacement original"}) in
  let replacement_store=Masc.Lane_addon_store.create
    ~root:(Filename.concat (Workspace_core.masc_dir config) "replacement-lane-addons") in
  retain replacement_store second;
  let request_id=get (O.attempt_request_id ~verification_id ~attempt:0) in
  let scope="verifier-reviews" in
  let replacement=match get (Masc.Lane_addon_store.load_tool_request_owner
      replacement_store ~scope ~request_id) with
    | Some value -> value | None -> Alcotest.fail "replacement owner missing" in
  let digest=get (V.digest second) in
  let body=match get (Masc.Lane_addon_store.load_tool_request_body
      replacement_store ~scope ~request_digest:digest) with
    | Some value -> value | None -> Alcotest.fail "replacement body missing" in
  (* A private fixture replaces the owner after a separate read. This exercises
     the identity returned by the worker; it does not claim an owner swap is a
     supported production transition. *)
  get (Masc.Lane_addon_store.save_tool_request_body store ~scope ~request_digest:digest body);
  get (Masc.Lane_addon_store.save_tool_request_owner store ~scope ~request_id replacement);
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
      ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    Alcotest.(check string) "worker sends its own loaded prompt" (V.system_prompt_text second) prompt;
    Ok {AR.selected_runtime_id="fixture-reviewer";evaluator_execution=None;verdict=Some (AR.Approve "checked replacement")}) (fun () ->
    match W.run_attempt ~prepare_notes:domain_notes ~store ~verification_id ~attempt:0
      ~installation_id ~package_id ~base_path:config.base_path ~prepare_authority:(fun () -> Ok a)
      ~provider_rest:(fun _ -> AR.No_stated_rest) () with
    | Error _ -> Alcotest.fail "replacement original did not run"
    | Ok (reviewed,result) ->
      Alcotest.(check bool) "separate earlier read names a different original" true
        (get (V.digest earlier) <> get (V.digest reviewed));
      Alcotest.(check bool) "worker returns exactly the original it reviewed" true
        (Yojson.Safe.equal (V.to_json second) (V.to_json reviewed));
      let saved=loaded (O.load_retained ~store ~verification_id ~attempt:0 ~installation_id ~package_id) in
      (match P.phase (O.progress saved) with
       | Judged judgment ->
         let retained_result,_=get (O.judgment_of_json ~original:reviewed judgment) in
         Alcotest.(check bool) "returned result is bound to that retained judgment" true
           (Yojson.Safe.equal (O.result_to_json result) (O.result_to_json retained_result))
       | Captured | Admission_wait _ | Dispatch_pending _ | Committing _ | Commit_unknown _
       | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
         Alcotest.fail "worker did not retain its judgment")))

let test_frozen_prompt_media_and_lookup () = with_workspace (fun config store ->
  let a = authority config in
  (* A frozen inventory observation remains valid after admission stops doing
     that inventory. Grants are bound by the complete authority digest. *)
  let first = original ~lookup_root:(AR.Producer_tree ["old-observed-checkout"]) a 0 in
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
    let identity = get (Runtime_response_identity.make ~execution_id:"retained-execution"
      ~actor:"reviewer" ~runtime_id:"fixture-reviewer" ~response_id:"accepted-response"
      ~provider_id:"fixture-provider" ~model_id:"fixture-model" ~tool_use_id:"verdict-call"
      ~provider_turn:2 ~source_tool_use_ordinal:0) in
    let calls = ref 0 in
    with_reviewer (fun ~base_path ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
        ?system_prompt ?goal_blocks ~report_tool_schema:_ ~lookup ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls;
      Alcotest.(check string) "original workspace reaches reviewer" config.base_path base_path;
      Alcotest.(check string) "exact stored prompt reaches reviewer" (V.system_prompt_text first) prompt;
      Alcotest.(check (option string)) "exact original system instructions reach reviewer"
        (Some (V.system_instructions first)) system_prompt;
      let expected = Agent_core.Types.image_block ~media_type:image.image_media_type
        ~source:(Agent_core.Types.Stored
          (Agent_core.History.stored_of_raw (Base64.decode_exn image.image_body_base64))) in
      Alcotest.(check bool) "original media reaches reviewer" true (goal_blocks=Some [Agent_core.Types.text_block prompt;expected]);
      (match lookup.AR.dispatch ~name:"tool_read_file" ~args:(`Assoc ["file_path",`String "receipt.txt"]) with
       | Tool_result.Completed payload ->
         Alcotest.(check bool) "successful owned lookup retains shared evidence projection" true
           (Yojson.Safe.Util.member "evidence_lookup_succeeded" payload.data = `Bool true)
       | Tool_result.Failed _ | Tool_result.Deferred _ -> Alcotest.fail "owned evidence read failed");
      Ok {AR.selected_runtime_id="fixture-reviewer";evaluator_execution=Some identity;verdict=Some (AR.Approve "checked")})
      (fun () -> match run store a 0 with
       | Ok {AR.verdict=Some (Approve "checked");evaluator_execution;_} ->
         Alcotest.(check bool) "actual winning response identity survives fresh review" true
           (evaluator_execution=Some identity);
         (match run store a 0 with
          | Ok result -> Alcotest.(check bool) "retained result preserves exact winning response" true
              (result.evaluator_execution=Some identity)
          | Error _ -> Alcotest.fail "retained winner did not restore");
         Alcotest.(check int) "restore does not replay provider" 1 !calls
       | Ok _ | Error _ -> Alcotest.fail "retained review did not return the structured verdict")))

let test_refusals_dispatch_nothing () = with_workspace (fun config store ->
  let a = authority config in
  let calls = ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
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
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error () ->
    incr calls;
    Alcotest.(check string) "retry preserves exact prompt" (V.system_prompt_text first) prompt;
    if !calls=1 then (
      let error=Agent_core.Error.Api (Agent_core.Error.Retry.RateLimited
        {retry_after=None;message="definite complete HTTP refusal"}) in
      on_runtime_attempt_error ~runtime_id:"fixture-reviewer" ~attempt:0
        ~dispatch:Runtime_attempt_dispatch.Dispatched error; Error error)
    else Ok {AR.selected_runtime_id="fixture-reviewer";evaluator_execution=None;verdict=Some (AR.Approve "retry checked")}) (fun () ->
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

let test_bound_scope_before_dispatch_failure_has_safe_retry () = with_workspace (fun config store ->
  let a=authority config in
  retain store (original a 0);
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
      ~attempt_continuation:_ ~on_runtime_attempt_error () ->
    let owner=match execution_owner with Some owner -> owner | None -> Alcotest.fail "original owner missing" in
    get (owner.AR.on_execution_ready ~runtime_id:"fixture-reviewer" ~execution:Types_core.Official_session);
    let error=Agent_core.Error.Api (Agent_core.Error.Retry.NetworkError
      {message="connection failed before dispatch";kind=Llm_provider.Http_client.Connection_refused}) in
    on_runtime_attempt_error ~runtime_id:"fixture-reviewer" ~attempt:0
      ~dispatch:Runtime_attempt_dispatch.Rejected_before_dispatch error;
    Error error) (fun () ->
    (match run store a 0 with
     | Ok {AR.verdict=None;retryable_runtimes=_::_;_} -> ()
     | Ok _ | Error _ -> Alcotest.fail "confirmed scope plus known no-effect refusal was stranded");
    let next=loaded (O.next_attempt ~store ~verification_id ~installation_id ~package_id) in
    Alcotest.(check int) "only a definite typed refusal authorizes the linked successor" 1 next))

let test_unknown_and_cancelled_never_redispatch () = with_workspace (fun config store ->
  let a=authority config in retain store (original a 0);
  let calls=ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
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
        (match run store a 0 with Error (W.Execution_repair_required _) -> ()
         | Ok _ | Error _ -> Alcotest.fail "lost response was treated as known completion");
        let restored=loaded (O.next_attempt ~store ~verification_id ~installation_id ~package_id) in
        Alcotest.(check int) "unknown keeps original identity" 0 restored;
        (match run store a restored with Error (W.Execution_repair_required _) -> ()
         | Ok _ | Error _ -> Alcotest.fail "unknown original replayed");
        Alcotest.(check int) "neither fallback nor restart dispatches" 1 !calls)));
  with_workspace (fun config store ->
    let a=authority config in retain store (original a 0);
    let calls=ref 0 in
    with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
        ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls;
      raise (Eio.Cancel.Cancelled Exit)) (fun () ->
        (try ignore (run store a 0);Alcotest.fail "cancellation swallowed"
         with Eio.Cancel.Cancelled _ -> ());
        (match run store a 0 with Error (W.Execution_repair_required _) -> ()
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

let test_actual_host_commit_restart () = with_workspace_runtime (fun config store clock ->
  let task=prepare_domain config in
  let a=authority config in let first=original a 0 in retain store first;
  let calls=ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls;Ok {AR.selected_runtime_id="fixture-reviewer";evaluator_execution=None;verdict=Some (AR.Approve "checked")}) (fun () ->
    let result=loaded (run_observed ~clock ~task ~store ~installation_id ~package_id first a) in
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

(* A rejection leaves the Task nonterminal and the producer edits its handoff
   right after. The commit must read back as applied from the rejection relation
   the domain commit wrote, not from handoff fields the producer may change. *)
let test_reject_commit_is_confirmed_by_its_relation () = with_workspace_runtime (fun config store clock ->
  let task=prepare_domain config in
  let a=authority config in let first=original a 0 in retain store first;
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    Ok {AR.selected_runtime_id="fixture-reviewer";evaluator_execution=None;verdict=Some (AR.Reject "repair needed")}) (fun () ->
    let result=loaded (run_observed ~clock ~task ~store ~installation_id ~package_id first a) in
    get (Host.commit_original ~config ~task ~store ~attempt:0 ~installation_id ~package_id
      ~verification_id ~notes:(domain_notes result));
    (match (task_in_backlog config).Masc_domain.task_status with
     | InProgress {assignee;_} -> Alcotest.(check string) "rejection returns the Task to its producer" producer assignee
     | Todo | Claimed _ | AwaitingVerification _ | Done _ | Cancelled _ -> Alcotest.fail "rejection was not applied");
    let backlog=get (Workspace_backlog.read_backlog_r config) in
    Workspace_core.write_backlog config {backlog with tasks=List.map (fun (task:Masc_domain.task) ->
      {task with handoff_context=Some {Masc_domain.summary="resumed the repair";reason=None;next_step=Some "fix it";
        failure_mode=None;reclaim_policy=None;evidence_refs=["board:p-1"];updated_at=None;updated_by=Some producer}})
      backlog.tasks};
    let finished=loaded (O.load_retained ~store ~verification_id ~attempt:0 ~installation_id ~package_id) in
    match P.phase (O.progress finished) with
    | P.Finished commit ->
      Alcotest.(check bool) "producer handoff edit does not change what the commit read back" true
        (Yojson.Safe.equal commit.P.change.P.after
           (get (Host.observe_original ~config ~original:(O.original finished) ~judgment:commit.P.judgment
              ~authority:Publication.authority commit.P.change)))
    | _ -> Alcotest.fail "rejection commit was not confirmed"))

let test_actual_host_commit_cancel_after_domain_write () =
  with_workspace_runtime (fun config store clock -> Eio.Switch.run (fun sw ->
  let installation_id=host_installation and package_id=host_package in
  let task=prepare_domain config in let a=authority config in let first=original a 0 in
  retained (O.retain ~store ~verification_id ~attempt:0 ~installation_id ~package_id first);
  let calls=ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls;Ok {AR.selected_runtime_id="fixture-reviewer";evaluator_execution=None;verdict=Some (AR.Approve "checked")}) (fun () ->
    let result=loaded (run_observed ~clock ~task ~store ~installation_id ~package_id first a) in
    let notes=domain_notes result in
    let hook=Atomic.get Workspace_hooks.task_terminal_committed_fn in
    Fun.protect ~finally:(fun () -> Atomic.set Workspace_hooks.task_terminal_committed_fn hook) (fun () ->
      Atomic.set Workspace_hooks.task_terminal_committed_fn
        (fun _ ~actor:_ ~task_id:_ -> raise (Eio.Cancel.Cancelled Exit));
      (try
         ignore (Host.commit_original ~config ~task ~store ~attempt:0
           ~installation_id ~package_id ~verification_id ~notes);
         Alcotest.fail "post-write cancellation did not propagate"
       with Eio.Cancel.Cancelled _ -> ()));
    let unfinished=loaded (pending ~store ~installation_id ~package_id) in
    Alcotest.(check int) "boot finds pending commit after Task left awaiting" 1 (List.length unfinished);
    let restarted=task_in_backlog config in
    (match restarted.Masc_domain.task_status with Done _ -> ()
     | Todo | Claimed _ | InProgress _ | AwaitingVerification _ | Cancelled _ -> Alcotest.fail "domain commit not applied");
    let path=Filename.concat (Workspace_core.masc_dir config) "fixture-verification-runs.jsonl" in
    let registry=R.replay path in
    get (Host.process_original_once ~registry ~config ~sw ~clock ~task:restarted
      ~assignee:producer ~verification_id);
    Alcotest.(check int) "boot confirms domain receipt and terminal observer ACK" 0
      (List.length (loaded (pending ~store ~installation_id ~package_id)));
    (match R.get (R.replay path) ~verification_id with
     | Some {status=Completed {outcome=Approved {reason="checked"};_};_} -> ()
     | Some _ | None -> Alcotest.fail "actual durable registry lost the retained approval");
    let bytes=Fs_compat.load_file path in
    get (Host.process_original_once ~registry:(R.replay path) ~config ~sw ~clock
      ~task ~assignee:producer ~verification_id);
    Alcotest.(check string) "stale Awaiting call preserves acknowledged Committed history" bytes (Fs_compat.load_file path);
    (match W.commit_attempt ~store ~verification_id ~attempt:0 ~installation_id ~package_id
       ~change:{P.before=`Null;after=`Null}
       ~observe:(fun _ -> Alcotest.fail "acknowledged Finished reread the domain")
       ~apply:(fun _ -> Alcotest.fail "acknowledged Finished reapplied") with
     | Ok () -> () | Error _ -> Alcotest.fail "authenticated Finished receipt was not reusable");
    Alcotest.(check int) "domain cancellation does not call another model" 1 !calls)))

let test_judgment_recovery_precedes_actual_preparation () =
  with_workspace_runtime (fun config store clock ->
    Eio.Switch.run (fun sw ->
      let task=prepare_domain config in
      let a=authority config in let first=original a 0 in
      let installation_id="masc.completion-authority" in
      let package_id="masc.completion-authority.review" in
      retained (O.retain ~store ~verification_id ~attempt:0 ~installation_id ~package_id first);
      let calls=ref 0 in
      with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
          ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
        incr calls;Ok {AR.selected_runtime_id="fixture-reviewer";evaluator_execution=None;verdict=Some (AR.Approve "checked")}) (fun () ->
        let result=loaded (run_observed ~clock ~task ~store ~installation_id ~package_id first a) in
        let saved=loaded (O.load_retained ~store ~verification_id ~attempt:0 ~installation_id ~package_id) in
        (match Masc.Lane_addon_request_progress.phase (O.progress saved) with
         | Judged _ -> ()
         | Captured | Admission_wait _ | Dispatch_pending _ | Committing _ | Commit_unknown _ | Finished _
         | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> Alcotest.fail "fixture crossed commit boundary too early");
        (* This request was deliberately never published to Verification: real
           prepare_review would fail before it could rebuild a remote layout. *)
        (match Verification.load_request config.Workspace_core.base_path verification_id with
         | Error _ -> () | Ok _ -> Alcotest.fail "preparation refusal fixture is not real");
        let registry=R.replay (Filename.concat (Workspace_core.masc_dir config) "fixture-verification-runs.jsonl") in
        get (Masc.Completion_authority_agent.For_testing.process_original_once
          ~registry ~config ~sw ~clock ~task ~assignee:producer ~verification_id);
        Alcotest.(check int) "actual production restart never reaches another provider" 1 !calls;
        (match (task_in_backlog config).Masc_domain.task_status with
         | Done {notes=Some notes;_} -> Alcotest.(check string) "commit uses exact retained judgment notes"
             (domain_notes result) notes
         | Todo | Claimed _ | InProgress _ | AwaitingVerification _ | Done _ | Cancelled _ ->
           Alcotest.fail "production host did not recover Judged without preparation"))))

let test_commit_unknown_recovers_exact_original () = with_workspace (fun config store ->
  let a=authority config in let first=original a 0 in retain store first;
  let calls=ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls;Ok {AR.selected_runtime_id="fixture-reviewer";evaluator_execution=None;verdict=Some (AR.Reject "repair")}) (fun () ->
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
      incr commits;domain:=after;Error (W.Outcome_unknown
         {error="reply lost after domain commit";detail="reply lost after domain commit"}) in
    (match W.commit_attempt ~store ~verification_id ~attempt:0 ~installation_id ~package_id
      ~change:{Masc.Lane_addon_request_progress.before;after} ~observe ~apply with
     | Error (W.Apply_failed _) -> () | Ok _ | Error _ -> Alcotest.fail "unknown commit not retained");
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
    with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime ~candidate_kind:_ ~prompt:_
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
          else Ok {AR.selected_runtime_id=runtime_id;evaluator_execution=None;verdict=Some (AR.Approve "checked")} in
          result,None,Masc.Keeper_provider_attempt_effect.No_effect_observed,
          Masc.Keeper_attempt_dispatch.Dispatched)
        ["first-provider";"second-provider"]) (fun () ->
      if retained_request then (
        (match run store a 0 with Error (W.Execution_repair_required _) -> ()
         | Ok _ | Error _ -> Alcotest.fail "retained actual inner walk lost uncertainty");
        Alcotest.(check (list string)) "actual inner admission blocks the second provider"
          ["first-provider"] (List.rev !calls);
        (match run store a 0 with Error (W.Execution_repair_required _) -> ()
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
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
      ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls;
    Alcotest.(check string) "re-admission preserves original prompt" (V.system_prompt_text first) prompt;
    Ok {AR.selected_runtime_id="fixture-reviewer";evaluator_execution=None;verdict=Some (AR.Approve "admitted")}) (fun () ->
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

let with_observed_host f = with_workspace_runtime (fun config store clock ->
  Eio.Switch.run (fun sw ->
    let task=prepare_domain config in let a=authority config in let first=original a 0 in
    retained (O.retain ~store ~verification_id ~attempt:0
      ~installation_id:host_installation ~package_id:host_package first);
    let calls=ref 0 in
    with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
        ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
        ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      incr calls;Ok {AR.selected_runtime_id="fixture-reviewer";evaluator_execution=None;verdict=Some (AR.Approve "checked")})
      (fun () -> f ~config ~store ~clock ~sw ~task ~first ~authority:a ~calls)))

let load_host store = loaded (O.load_retained ~store ~verification_id ~attempt:0
  ~installation_id:host_installation ~package_id:host_package)

let test_calibration_uses_original_on_readmission () =
  with_workspace_runtime (fun config store clock -> Eio.Switch.run (fun sw ->
    let module Cal = Masc.Eval_calibration in
    Cal.For_testing.set_store ~base_path:config.Workspace_core.base_path;
    Fun.protect ~finally:Cal.For_testing.reset_store (fun () ->
      let task=prepare_domain config in
      let identity ~actor ~runtime_id ~model_id suffix =
        get (Runtime_response_identity.make ~execution_id:("execution-" ^ suffix)
          ~actor ~runtime_id ~response_id:("response-" ^ suffix) ~provider_id:"fixture-provider"
          ~model_id ~tool_use_id:("call-" ^ suffix) ~provider_turn:1 ~source_tool_use_ordinal:0) in
      let original_producer=identity ~actor:producer ~runtime_id:"producer-runtime"
        ~model_id:"original-model" "original" in
      let wake_producer=identity ~actor:producer ~runtime_id:"producer-runtime"
        ~model_id:"replacement-model" "replacement" in
      let evaluator=identity ~actor:"fixture-reviewer" ~runtime_id:"fixture-reviewer"
        ~model_id:"evaluator-model" "evaluator" in
      let output note producer_execution = `Assoc [
        "completion_note", `String note;
        "producer_execution", Runtime_response_identity.to_yojson producer_execution;
        "evidence_refs", `List [`String "note:fixture"];
        "required_artifacts", `List [];
        "submitted_evidence", `List [Store.submitted_evidence_item_to_yojson
          (Store.Evidence_note "fixed submitted evidence")]] in
      let submitted=get (Verification.create_request ~base_path:config.base_path
        ~task_id ~worker:producer ~request_id:verification_id ~criteria:[]
        ~output:(output "original completion note" original_producer) ()) in
      (match get (Verification.producer_execution submitted) with
       | Some observed -> Alcotest.(check bool) "submission records the original producer execution" true
           (observed=original_producer)
       | None -> Alcotest.fail "fixture submission has no producer execution");
      let path=Filename.concat (Workspace_core.masc_dir config) "calibration-review-runs.jsonl" in
      let reviewer_calls=ref 0 and expected_prompt=ref None in
      with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
          ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
          ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
        incr reviewer_calls;
        (match !expected_prompt with
         | Some expected -> Alcotest.(check string) "reviewer receives the retained original" expected prompt
         | None -> Alcotest.fail "reviewer ran before the original was captured");
        Ok {AR.selected_runtime_id="fixture-reviewer";evaluator_execution=Some evaluator;
          verdict=Some (AR.Approve "checked original")}) (fun () ->
        Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
          (fun () -> Error "fixture admission unavailable");
        (match Host.process_original_once ~registry:(R.replay path) ~config ~sw ~clock
           ~task ~assignee:producer ~verification_id with
         | Error _ -> () | Ok () -> Alcotest.fail "unavailable admission unexpectedly committed");
        Alcotest.(check int) "first wake did not dispatch a reviewer" 0 !reviewer_calls;
        Alcotest.(check int) "no verdict was calibrated before admission" 0
          (List.length (Dated_jsonl.read_recent (Cal.get_store ()) 10));
        let captured=load_host store in
        (match P.phase (O.progress captured) with
         | Admission_wait _ -> ()
         | Captured | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
         | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
           Alcotest.fail "first wake did not retain admission wait");
        let original=O.original captured in
        let frozen=V.review_request original in
        Alcotest.(check (option string)) "original generator runtime remains bound"
          (Some "producer-runtime") (V.generator_runtime original);
        expected_prompt:=Some (V.system_prompt_text original);
        Alcotest.(check string) "captured title" task.Masc_domain.title frozen.AR.task_title;
        let original_note=Yojson.Safe.Util.(Yojson.Safe.from_string frozen.completion_notes
          |> member "verification_request" |> member "output" |> member "completion_note" |> to_string) in
        Alcotest.(check string) "captured completion note" "original completion note" original_note;
        let backlog=get (Workspace_backlog.read_backlog_r config) in
        Workspace_core.write_backlog config {backlog with tasks=List.map (fun (task:Masc_domain.task) ->
          if task.id=task_id then {task with title="edited wake title"} else task) backlog.tasks};
        (* Replace only fixture input fields while preserving the saved subject
           and submitted snapshot. No producer or new submission is executed. *)
        let changed={submitted with output=output "edited wake completion note" wake_producer} in
        let request_path=Filename.concat (Store.verifications_dir config.base_path)
          (verification_id ^ ".json") in
        get (Fs_compat.save_file_atomic request_path
          (Yojson.Safe.pretty_to_string (Verification.request_to_yojson changed)));
        let wake_task=task_in_backlog config in
        Alcotest.(check string) "re-entry sees edited Task title" "edited wake title" wake_task.title;
        let wake_request=get (Verification.load_request config.base_path verification_id) in
        Alcotest.(check string) "re-entry sees edited completion note" "edited wake completion note"
          Yojson.Safe.Util.(wake_request.output |> member "completion_note" |> to_string);
        (match get (Verification.producer_execution wake_request) with
         | Some observed ->
           Alcotest.(check bool) "wake carries the different producer execution" true
             (observed=wake_producer && observed<>original_producer);
           Alcotest.(check string) "both producer executions use the same actor" original_producer.actor observed.actor;
           Alcotest.(check string) "both producer executions use the same runtime" original_producer.runtime_id observed.runtime_id
         | None -> Alcotest.fail "fixture wake has no producer execution");
        Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
          (fun () -> Ok ["fixture-reviewer",Types_core.Catalog_slot]);
        get (Host.process_original_once ~registry:(R.replay path) ~config ~sw ~clock
          ~task:wake_task ~assignee:producer ~verification_id);
        Alcotest.(check int) "re-admission dispatches one reviewer" 1 !reviewer_calls;
        let rows ()=Dated_jsonl.read_recent (Cal.get_store ()) 10 in
        let row=match rows () with [row] -> row
          | _ -> Alcotest.fail "expected exactly one actual calibration row" in
        let expected_hash=Agent_core_sha256.(digest_string
          (frozen.task_title ^ "\n" ^ frozen.completion_notes) |> to_hex) in
        Alcotest.(check string) "calibration title is the reviewed title" frozen.task_title
          Yojson.Safe.Util.(row |> member "task_title" |> to_string);
        Alcotest.(check string) "calibration hash binds reviewed title and notes" expected_hash
          Yojson.Safe.Util.(row |> member "notes_hash" |> to_string);
        Alcotest.(check string) "calibration row names the original Task" task_id
          Yojson.Safe.Util.(row |> member "task_id" |> to_string);
        Alcotest.(check string) "calibration row has the actual verdict" "approve:checked original"
          Yojson.Safe.Util.(row |> member "verdict" |> to_string);
        Alcotest.(check bool) "calibration does not attribute the wake producer execution" true
          (Yojson.Safe.Util.member "producer_execution" row = `Null);
        Alcotest.(check string) "calibration keeps the original generator runtime" "producer-runtime"
          Yojson.Safe.Util.(row |> member "generator_runtime" |> to_string);
        Alcotest.(check bool) "calibration retains the observed evaluator execution" true
          (Yojson.Safe.equal (Runtime_response_identity.to_yojson evaluator)
            (Yojson.Safe.Util.member "evaluator_execution" row));
        let model_pairs=Yojson.Safe.Util.member "model_identity_observation" (Cal.calibration_stats ()) in
        Alcotest.(check int) "unbound producer is excluded from observed model pairs" 0
          Yojson.Safe.Util.(model_pairs |> member "observed_verdict_count" |> to_int);
        Alcotest.(check int) "unbound producer is counted as unobserved" 1
          Yojson.Safe.Util.(model_pairs |> member "unobserved_causes" |> member "producer" |> to_int);
        get (Host.process_original_once ~registry:(R.replay path) ~config ~sw ~clock
          ~task:(task_in_backlog config) ~assignee:producer ~verification_id);
        Alcotest.(check int) "committed recovery does not dispatch another reviewer" 1 !reviewer_calls;
        Alcotest.(check bool) "committed recovery does not rewrite calibration" true (rows ()=[row])))))

let operator_act config = function
  | `Cancelled -> get (Workspace.cancel_task_as_operator_r config ~operator_id:"race-operator"
      ~task_id ~reason:"operator won before the retained verifier commit" ()
      |> Result.map_error Masc_domain.masc_error_to_string)
  | `Done | `Rejected as choice ->
    let verdict=match choice with `Done -> Masc_domain.Verdict_approved
      | `Rejected -> Masc_domain.Verdict_rejected {reason="operator requests repair"} in
    get (Workspace.commit_verdict_r config ~authority:(Masc_domain.Human_operator {operator_id="race-operator"})
      ~task_id ~verification_id ~verdict ~notes:"operator-owned decision" ()
      |> Result.map_error Masc_domain.masc_error_to_string)

let assert_terminal_ack store =
  let saved=load_host store in
  (match (P.observer (O.progress saved)).completion with
   | Masc.Lane_addon_request_receipt.Acknowledged _ -> ()
   | Unobserved | Pending _ -> Alcotest.fail "terminal publication was not acknowledged");
  Alcotest.(check int) "acknowledged original leaves pending discovery" 0
    (List.length (loaded (pending ~store ~installation_id:host_installation ~package_id:host_package)))

let test_judged_boot_respects_terminal_operator () =
  List.iter (fun terminal -> with_observed_host (fun ~config ~store ~clock ~sw ~task ~first ~authority ~calls ->
    ignore (loaded (run_observed ~clock ~task ~store ~installation_id:host_installation
      ~package_id:host_package first authority));
    ignore (operator_act config terminal);
    let current=task_in_backlog config in
    let before=Masc_domain.task_to_yojson current in
    let captured=get (Masc.Verifier_review_commit_intent.before_of_status ~original:first task.task_status) in
    let malformed_before=match captured with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
          if key="status" then key,(match value with `Assoc status -> `Assoc (("unknown_metadata",`Null)::status)
            | _ -> Alcotest.fail "captured Task status is not an object") else key,value) fields)
      | _ -> Alcotest.fail "captured before-state is not an object" in
    (match Masc.Verifier_review_commit_intent.before_status ~original:first malformed_before with
     | Error _ -> () | Ok _ -> Alcotest.fail "lossy status decoding accepted unknown captured metadata");
    let path=Filename.concat (Workspace_core.masc_dir config) "terminal-operator-runs.jsonl" in
    let registry=R.replay path in
    let outcome=Host.process_original_once ~registry ~config ~sw ~clock ~task:current
      ~assignee:producer ~verification_id in
    let authority=match R.get (R.replay path) ~verification_id with
     | Some {status=Completed {outcome=Superseded_by {authority};_};_} ->
       Alcotest.(check bool) "durable terminal authority is nonblank" true (String.length authority>0);
       authority
     | Some _ | None -> Alcotest.fail "actual durable publication was not superseded" in
    expect_superseded ~authority outcome;
    Alcotest.(check bool) "late verifier preserves actual operator state" true
      (Yojson.Safe.equal before (Masc_domain.task_to_yojson (task_in_backlog config)));
    (match P.phase (O.progress (load_host store)) with
     | Conflicted _ -> () | _ -> Alcotest.fail "third-state authority was not durably conflicted");
    assert_terminal_ack store;
    let bytes=Fs_compat.load_file path in
    expect_superseded ~authority (Host.process_original_once ~registry:(R.replay path) ~config ~sw ~clock
      ~task ~assignee:producer ~verification_id);
    assert_terminal_ack store;
    Alcotest.(check string) "stale queued Awaiting call cannot reset acknowledged Superseded row"
      bytes (Fs_compat.load_file path);
    let malformed=match current.Masc_domain.task_status with
      | Done done_ -> {current with task_status=Done {done_ with assignee=""}}
      | Cancelled cancelled -> {current with task_status=Cancelled {cancelled with cancelled_by=""}}
      | _ -> Alcotest.fail "operator terminal fixture is not terminal" in
    (match Publication.terminal_authority_of_conflict ~task_id
       (`Assoc ["conflicting_task",Masc_domain.task_to_yojson malformed]) with
     | Error _ -> () | Ok _ -> Alcotest.fail "blank terminal identity became quiet authority");
    Alcotest.(check int) "terminal boot never invokes another reviewer" 1 !calls)) [`Done;`Cancelled]

let test_actual_before_apply_authority_race () =
  List.iter (fun terminal -> with_observed_host (fun ~config ~store ~clock ~sw:_ ~task ~first ~authority ~calls ->
    ignore (loaded (run_observed ~clock ~task ~store ~installation_id:host_installation
      ~package_id:host_package first authority));
    let saved=load_host store in
    let judgment=match P.phase (O.progress saved) with
      | Judged judgment -> judgment
      | _ -> Alcotest.fail "actual worker did not retain its judgment" in
    let before=get (Masc.Verifier_review_commit_intent.before_of_status
      ~original:first (get (Publication.captured_before saved))) in
    let change=get (Masc.Verifier_review_commit_intent.prepare ~original:first ~judgment
      ~authority:Publication.authority ~before) in
    let reads=ref 0 and applies=ref 0 in
    let observe change = incr reads;
      Host.observe_original ~config ~original:first ~judgment
        ~authority:Publication.authority change in
    let apply change =
      incr applies;ignore (operator_act config terminal);
      let refused=Host.apply_original ~config ~original:first ~judgment
        ~authority:Publication.authority change in
      (match refused with
       | Error (W.Authority_refused {error=Host.Workspace_commit_refused
           (Masc_domain.Task (Masc_domain.Task_error.InvalidState _));_}) -> ()
       | _ -> Alcotest.fail "real operator race did not produce the actual typed InvalidState refusal");
      refused in
    let attempted=W.commit_attempt ~store ~verification_id ~attempt:0
      ~installation_id:host_installation ~package_id:host_package ~change ~observe ~apply in
    let observed=match attempted with
      | Error (W.Commit_conflicted {observed;_}) -> observed
      | Ok _ | Error _ -> Alcotest.fail "actual before/apply race did not retain its authoritative conflict" in
    Alcotest.(check int) "one real apply; refusal never reapplies" 1 !applies;
    Alcotest.(check int) "one before-read and one refusal read" 2 !reads;
    (match terminal,Publication.terminal_authority_of_conflict ~task_id observed with
     | (`Done | `Cancelled),Ok _ | `Rejected,Error _ -> ()
     | _ -> Alcotest.fail "nonterminal refusal was confused with quiet terminal authority");
    let reopened=Masc.Lane_addon_store.create ~root:(Masc.Lane_addon_store.root store) in
    (match W.commit_attempt ~store:reopened ~verification_id ~attempt:0
       ~installation_id:host_installation ~package_id:host_package ~change:{P.before=`Null;after=`Null}
       ~observe:(fun _ -> Alcotest.fail "cached conflict reread the Task")
       ~apply:(fun _ -> Alcotest.fail "cached conflict reapplied") with
     | Error (W.Commit_conflicted _) -> ()
     | Ok _ | Error _ -> Alcotest.fail "reopened original lost its typed conflict");
    Alcotest.(check int) "operator race and restart retain one review" 1 !calls)) [`Done;`Cancelled;`Rejected]

let test_atomic_judgment_observation_unconfirmed () = with_observed_host
  (fun ~config ~store ~clock ~sw ~task ~first ~authority ~calls ->
    let started_at=Eio.Time.now clock in
    let path=Filename.concat (Workspace_core.masc_dir config) "unconfirmed-runs.jsonl" in
    let registry=R.replay path in
    R.register_running registry ~verification_id ~task_id ~producer
      ~authority_kind:(Masc_domain.completion_authority_kind Publication.authority)
      ~authority_actor:(Masc_domain.completion_authority_actor Publication.authority) ~started_at;
    let before=Fs_compat.load_file path in
    let writes=ref 0 in
    let save_then_error store ~scope ~request_id json =
      incr writes;
      match Masc.Lane_addon_store.save_tool_request_owner store ~scope ~request_id json with
      | Ok () -> Error "lost owner publication reply after actual durable save"
      | Error detail -> Error detail in
    let advance_events ~store retained events = match events with
      | [P.Judgment_retained _; Observer (Masc.Lane_addon_request_receipt.Intended (Registration,_))] ->
        O.For_testing.advance_events
          ~publish:(Masc.Lane_addon_tool_request_owner.For_testing.advance_events ~save:save_then_error)
          ~store retained events
      | _ -> O.advance_events ~store retained events in
    let result=W.For_testing.run_attempt ~advance_events ~prepare_notes:domain_notes
      ~prepare_observer_registration:(execution_observer ~clock ~started_at
        ~before:task.Masc_domain.task_status ~original:first)
      ~store ~verification_id ~attempt:0 ~installation_id:host_installation ~package_id:host_package
      ~base_path:(A.task_review_base_path authority) ~prepare_authority:(fun () -> Ok authority) ~provider_rest:(fun _ -> AR.No_stated_rest) () in
    (match result with Error (W.Persistence_unavailable _) -> ()
     | Ok _ | Error _ -> Alcotest.fail "actual unconfirmed save was not preserved as typed worker failure");
    Alcotest.(check int) "atomic judgment+registration uses one real final write" 1 !writes;
    let saved=load_host store in
    (match P.phase (O.progress saved),(P.observer (O.progress saved)).registration with
     | Judged _,Masc.Lane_addon_request_receipt.Pending _ -> ()
     | _ -> Alcotest.fail "durable atomic save split the judgment from actual observations");
    let overwritten=Host.unless_original_publication ~store ~verification_id ~task_id ~producer
      ~otherwise:(fun () -> R.mark_completed registry ~verification_id
        ~outcome:(R.Raised {detail="ordinary returned-error completion must not overwrite"})
        ~tools:[] ~elapsed_s:0. ()) in
    Alcotest.(check bool) "actual Caa returned-error guard preserves retained publication" false overwritten;
    Alcotest.(check string) "typed worker failure did not write a competing completion" before (Fs_compat.load_file path);
    get (Host.process_original_once ~registry:(R.replay path) ~config ~sw ~clock ~task
      ~assignee:producer ~verification_id);
    assert_terminal_ack store;
    Alcotest.(check int) "unconfirmed reply never invokes another reviewer" 1 !calls)

let test_terminal_publication_cancel_then_boot_without_task () = with_observed_host
  (fun ~config ~store ~clock ~sw ~task ~first ~authority ~calls ->
    ignore (loaded (run_observed ~clock ~task ~store ~installation_id:host_installation
      ~package_id:host_package first authority));
    ignore (operator_act config `Cancelled);
    let path=Filename.concat (Workspace_core.masc_dir config) "cancelled-publication-runs.jsonl" in
    let registry=R.replay path in
    let execution=match (P.observer (O.progress (load_host store))).registration with
      | Pending receipt -> get (R.completed_run_of_yojson (Yojson.Safe.Util.member "execution" receipt.payload))
      | _ -> Alcotest.fail "execution observations were not retained atomically" in
    (* Valid synthetic retention controls are newer than the actual target.
       The confirmed target therefore leaves the ordinary projection at once. *)
    for index=1 to R.max_completed_retained do
      let row={execution with verification_id=Printf.sprintf "retention-control-%d" index;
        task_id=Printf.sprintf "retention-task-%d" index;started_at=execution.started_at +. float_of_int (index+1000);
        status=R.Completed {outcome=R.Not_reviewed {gate="fixture";detail="retention control"};
          evaluator_runtime=None;elapsed_s=0.;tools=[]}} in
      get (R.publish_terminal_confirmed registry ~expected:row |> Result.map_error R.publication_error_to_string)
    done;
    let hook=Atomic.get R.change_observer_fn in
    Fun.protect ~finally:(fun () -> Atomic.set R.change_observer_fn hook) (fun () ->
      Atomic.set R.change_observer_fn (fun () -> raise (Eio.Cancel.Cancelled Exit));
      (try ignore (Host.process_original_once ~registry ~config ~sw ~clock
         ~task:(task_in_backlog config) ~assignee:producer ~verification_id);
         Alcotest.fail "post-confirmation cancellation did not propagate"
       with Eio.Cancel.Cancelled _ -> ()));
    (match R.get registry ~verification_id with None -> ()
     | Some _ -> Alcotest.fail "retention did not immediately prune the target projection");
    (match (P.observer (O.progress (load_host store))).completion with
     | Pending _ -> () | _ -> Alcotest.fail "cancelled completion must remain unacknowledged");
    let frozen=match (P.observer (O.progress (load_host store))).completion with
      | Pending receipt -> get (R.completed_run_of_yojson receipt.payload)
      | _ -> Alcotest.fail "pending exact completion disappeared" in
    ignore (get (Workspace.delete_task_r config ~task_id
      |> Result.map_error Masc_domain.masc_error_to_string));
    (match Workspace.read_task_inspection_r config ~task_id with
     | Ok (Task_unobserved | Task_deletion_recorded _) -> ()
     | Ok (Inspected_task _) | Error _ -> Alcotest.fail "actual deletion fixture still exposes a Task");
    let reopened=Masc.Lane_addon_store.create ~root:(Masc.Lane_addon_store.root store) in
    (* Actual registry replay compacts retained history. The absent original
       may therefore be reconstructed from its immutable pending receipt. *)
    let restarted_registry=R.replay path in
    let count,failures=get (Host.recover_original_publications ~registry:restarted_registry ~config ~sw ~clock) in
    Alcotest.(check int) "actual production boot discovers terminal original without Task" 1 count;
    Alcotest.(check (list string)) "boot publication failures" [] failures;
    assert_terminal_ack reopened;
    let acknowledged=match (P.observer (O.progress (load_host reopened))).completion with
      | Acknowledged receipt -> get (R.completed_run_of_yojson receipt.payload)
      | _ -> Alcotest.fail "recovered completion was not acknowledged" in
    Alcotest.(check bool) "recovery preserves the entire original pending row" true (frozen=acknowledged);
    (match frozen.status,execution.status with
     | R.Completed actual,R.Completed original ->
       Alcotest.(check bool) "recovery preserves original clock, tools, runtime and elapsed" true
         (frozen.started_at=execution.started_at && actual.tools=original.tools
           && actual.evaluator_runtime=original.evaluator_runtime && actual.elapsed_s=original.elapsed_s);
       (match actual.outcome with Superseded_by _ -> ()
        | _ -> Alcotest.fail "recovery changed the actual terminal outcome")
     | _ -> Alcotest.fail "recovery row lacks completion facts");
    let after_recovery=Fs_compat.load_file path in
    get (R.publish_terminal_confirmed restarted_registry ~expected:frozen
      |> Result.map_error R.publication_error_to_string);
    Alcotest.(check string) "fresh exact durable confirmation appends no different completion"
      after_recovery (Fs_compat.load_file path);
    let compacted_registry=R.replay path in
    let after_compaction=Fs_compat.load_file path in
    let authority=match frozen.status with
      | R.Completed {outcome=R.Superseded_by {authority};_} -> authority
      | Running | Completed _ -> Alcotest.fail "frozen terminal receipt is not superseded" in
    expect_superseded ~authority (Host.process_original_once ~registry:compacted_registry ~config ~sw ~clock
      ~task ~assignee:producer ~verification_id);
    assert_terminal_ack reopened;
    Alcotest.(check string) "stale Awaiting call cannot resurrect an ACKed pruned original"
      after_compaction (Fs_compat.load_file path);
    (match R.get compacted_registry ~verification_id with
     | None -> () | Some _ -> Alcotest.fail "stale call recreated the pruned registry row");
    let count,failures=get (Host.recover_original_publications ~registry:compacted_registry ~config ~sw ~clock) in
    Alcotest.(check int) "ACK prevents reactivation after registry compaction/pruning" 0 count;
    Alcotest.(check (list string)) "post-ACK boot failures" [] failures;
    Alcotest.(check string) "post-ACK discovery does not resurrect a pruned registry row"
      after_compaction (Fs_compat.load_file path);
    Alcotest.(check int) "publication boot never calls another model" 1 !calls)

let test_atomic_observation_cancel_then_actual_host () = with_observed_host
  (fun ~config ~store ~clock ~sw ~task ~first ~authority ~calls ->
    let started_at=Eio.Time.now clock in
    let path=Filename.concat (Workspace_core.masc_dir config) "atomic-cancel-runs.jsonl" in
    let registry=R.replay path in
    R.register_running registry ~verification_id ~task_id ~producer
      ~authority_kind:(Masc_domain.completion_authority_kind Publication.authority)
      ~authority_actor:(Masc_domain.completion_authority_actor Publication.authority) ~started_at;
    let before=Fs_compat.load_file path in
    (try ignore (W.run_attempt ~prepare_notes:domain_notes
       ~prepare_observer_registration:(execution_observer ~clock ~started_at
         ~before:task.Masc_domain.task_status ~original:first)
       ~on_verdict:(fun _ -> raise (Eio.Cancel.Cancelled Exit))
       ~store ~verification_id ~attempt:0 ~installation_id:host_installation ~package_id:host_package
       ~base_path:(A.task_review_base_path authority) ~prepare_authority:(fun () -> Ok authority) ~provider_rest:(fun _ -> AR.No_stated_rest) ());
       Alcotest.fail "post-atomic judgment cancellation did not propagate"
     with Eio.Cancel.Cancelled _ ->
       let overwritten=Host.unless_original_publication ~store ~verification_id ~task_id ~producer
         ~otherwise:(fun () -> R.mark_completed registry ~verification_id
           ~outcome:(R.Review_cancelled {detail="ordinary cancellation must not overwrite"})
           ~tools:[] ~elapsed_s:0. ()) in
       Alcotest.(check bool) "actual Caa cancellation guard preserves atomic original" false overwritten);
    Alcotest.(check string) "post-save cancellation does not publish competing completion" before (Fs_compat.load_file path);
    let saved=load_host store in
    (match List.rev (P.events (O.progress saved)) with
     | Observer (Masc.Lane_addon_request_receipt.Intended (Registration,_)) :: Judgment_retained _ :: _ -> ()
     | _ -> Alcotest.fail "actual judgment and observation were not one ordered owner publication");
    get (Host.process_original_once ~registry:(R.replay path) ~config ~sw ~clock ~task
      ~assignee:producer ~verification_id);
    assert_terminal_ack store;
    (match (task_in_backlog config).Masc_domain.task_status with
     | Done _ -> () | _ -> Alcotest.fail "fresh host did not commit the retained original");
    Alcotest.(check int) "post-save cancellation and fresh host retain one model call" 1 !calls)

let test_one_unpublishable_original_does_not_starve_boot () = with_observed_host
  (fun ~config ~store ~clock ~sw ~task ~first ~authority ~calls ->
    let result=loaded (run_observed ~clock ~task ~store ~installation_id:host_installation
      ~package_id:host_package first authority) in
    get (Host.commit_original ~config ~task ~store ~attempt:0 ~installation_id:host_installation
      ~package_id:host_package ~verification_id ~notes:(domain_notes result));
    (* This deliberately unpublishable owned journal has no execution receipt.
       It is a negative recovery control, never claimed as actual Task proof. *)
    let bad_id="unpublishable-control-1" in
    let bad=get (V.prepare ~generator_runtime:None ~verification_id:bad_id ~attempt:0 ~question
      ~lookup_root:(A.task_review_root authority)
      ~lookup_binding:(A.task_review_binding authority)
      ~lookup_schemas:(List.map (fun (schema:Types_core.tool_schema) -> schema.name)
        (A.schemas (A.task_review_tools authority))) request) in
    retained (O.retain ~store ~verification_id:bad_id ~attempt:0
      ~installation_id:host_installation ~package_id:host_package bad);
    let record=loaded (O.load_retained ~store ~verification_id:bad_id ~attempt:0
      ~installation_id:host_installation ~package_id:host_package) in
    let judgment=get (O.judgment_to_json ~original:bad ~notes:"unpublishable control" result) in
    ignore (loaded (O.advance_events ~store record [P.Dispatch_intended;Judgment_retained judgment;
      Commit_intended {before=`Null;after=`Null};Commit_conflicted (`Assoc ["unobserved",`Bool true])]));
    let inventoried=loaded (pending ~store ~installation_id:host_installation ~package_id:host_package) in
    (match inventoried with
     | bad::_ when V.verification_id (O.original bad)=bad_id -> ()
     | _ -> Alcotest.fail "negative control must precede the healthy original in actual discovery");
    let path=Filename.concat (Workspace_core.masc_dir config) "independent-publications.jsonl" in
    let count,failures=get (Host.recover_original_publications ~registry:(R.replay path) ~config ~sw ~clock) in
    Alcotest.(check int) "bad first key does not suppress actual healthy publication" 1 count;
    Alcotest.(check int) "unprovable original remains an explicit failure" 1 (List.length failures);
    (match (P.observer (O.progress (load_host store))).completion with
     | Masc.Lane_addon_request_receipt.Acknowledged _ -> ()
     | _ -> Alcotest.fail "healthy sibling did not reach its durable ACK");
    (match R.get (R.replay path) ~verification_id with
     | Some {status=Completed {outcome=Approved _;_};_} -> ()
     | _ -> Alcotest.fail "healthy sibling has no durable actual completion");
    Alcotest.(check int) "boot failures never cause a second review" 1 !calls)

let test_missing_observer_refuses_before_domain_mutation () =
  let exercise ~observed phase = with_observed_host
    (fun ~config ~store ~clock ~sw ~task ~first ~authority ~calls ->
      let result=loaded (if observed then
          run_observed ~clock ~task ~store ~installation_id:host_installation
            ~package_id:host_package first authority
        else (W.run_attempt ~prepare_notes:domain_notes ~store ~verification_id ~attempt:0
          ~installation_id:host_installation ~package_id:host_package
          ~base_path:(A.task_review_base_path authority) ~prepare_authority:(fun () -> Ok authority)
          ~provider_rest:(fun _ -> AR.No_stated_rest) () |> Result.map snd)) in
      Alcotest.(check int) "fixture actually ran its original reviewer" 1 !calls;
      let judged=load_host store in
      let judgment=match P.phase (O.progress judged) with
        | Judged judgment -> judgment
        | _ -> Alcotest.fail "actual worker did not retain its judgment" in
      let original=O.original judged in
      let before=get (Masc.Verifier_review_commit_intent.before_of_status
        ~original task.Masc_domain.task_status) in
      let change=get (Masc.Verifier_review_commit_intent.prepare
        ~original ~judgment ~authority:Publication.authority ~before) in
      let notes,_started_at,decoded,verdict=get (Masc.Verifier_review_commit_intent.decode
        ~original ~judgment ~authority:Publication.authority change) in
      Alcotest.(check string) "strict retained intent binds the actual host notes" (domain_notes result) notes;
      Alcotest.(check bool) "strict retained intent binds the actual review" true
        (Yojson.Safe.equal (O.result_to_json result) (O.result_to_json decoded));
      (match verdict with AR.Approve "checked" -> ()
       | _ -> Alcotest.fail "strict retained intent has no actual approval");
      Alcotest.(check bool) "actual host read confirms this valid intent could apply" true
        (Yojson.Safe.equal change.P.before (get (Host.observe_original ~config ~original
          ~judgment ~authority:Publication.authority change)));
      let staged=match phase with
        | `Judged -> judged
        | `Committing | `Commit_unknown -> loaded (O.advance ~store judged (P.Commit_intended change)) in
      let staged=match phase with
        | `Judged | `Committing -> staged
        | `Commit_unknown -> loaded (O.advance ~store staged
            (P.Commit_uncertain (`Assoc ["fixture",`String "retained commit reply unknown"]))) in
      (match phase,P.phase (O.progress staged) with
       | `Judged,Judged _ | `Committing,Committing _ | `Commit_unknown,Commit_unknown _ -> ()
       | _ -> Alcotest.fail "actual owner events did not reach the selected recovery phase");
      let events=P.events (O.progress staged) in
      let raw_task=Fs_compat.load_file (Workspace_backlog.backlog_path config) in
      let observations=ref 0 and applications=ref 0 in
      let observe ~config ~original ~judgment ~authority change =
        incr observations;Host.observe_original ~config ~original ~judgment ~authority change in
      let apply ~config ~original ~judgment ~authority change =
        incr applications;Host.apply_original ~config ~original ~judgment ~authority change in
      let commit ()=Host.commit_original_with_effects ~observe ~apply ~config ~task ~store ~attempt:0
        ~installation_id:host_installation ~package_id:host_package ~verification_id ~notes in
      let path=Filename.concat (Workspace_core.masc_dir config) "missing-observer-runs.jsonl" in
      let registry=R.replay path in
      let registry_bytes ()=if Fs_compat.file_exists path then Some (Fs_compat.load_file path) else None in
      let raw_registry=registry_bytes () in
      if observed then (
        get (commit ());
        Alcotest.(check int) "observed sibling executes exactly one real domain apply" 1 !applications;
        Alcotest.(check int) "observed sibling reads before and confirms after" 2 !observations;
        (match (task_in_backlog config).Masc_domain.task_status with
         | Done _ -> () | _ -> Alcotest.fail "observed valid sibling did not commit the actual Task");
        get (Host.process_original_once ~registry ~config ~sw ~clock ~task:(task_in_backlog config)
          ~assignee:producer ~verification_id);
        assert_terminal_ack store;
        (match R.get (R.replay path) ~verification_id with
         | Some {status=Completed {outcome=Approved {reason="checked"};_};_} -> ()
         | _ -> Alcotest.fail "observed sibling has no durable actual terminal publication"))
      else (
        (match (P.observer (O.progress staged)).registration with
         | Masc.Lane_addon_request_receipt.Unobserved -> ()
         | Pending _ | Acknowledged _ -> Alcotest.fail "negative control unexpectedly has observations");
        let missing="original execution observations were not retained; recovery cannot reconstruct tools or elapsed time" in
        let expect_missing = function
          | Error detail -> Alcotest.(check string) "exact missing observations cause the refusal" missing detail
          | Ok () -> Alcotest.fail "missing actual observations authorized a domain commit" in
        expect_missing (commit ());
        Alcotest.(check int) "missing observations refuse before actual host observation" 0 !observations;
        Alcotest.(check int) "missing observations refuse before actual domain apply call" 0 !applications;
        expect_missing (Host.process_original_once ~registry ~config ~sw ~clock ~task
          ~assignee:producer ~verification_id);
        Alcotest.(check string) "unprovable recovery preserves the raw actual Task"
          raw_task (Fs_compat.load_file (Workspace_backlog.backlog_path config));
        Alcotest.(check bool) "unprovable recovery preserves the exact owner phase and events" true
          (events=P.events (O.progress (load_host store)));
        Alcotest.(check (option string)) "unprovable recovery publishes no competing registry row"
          raw_registry (registry_bytes ()));
      Alcotest.(check int) "recovery never adds another reviewer call" 1 !calls) in
  List.iter (fun phase -> exercise ~observed:false phase;exercise ~observed:true phase)
    [`Judged;`Committing;`Commit_unknown]

let () =
  let prompts = Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts" in
  Prompt_registry.set_markdown_dir prompts;
  Prompt_registry.load_prompts_from_directory prompts;
  Masc_test_deps.init_unified_tool_registry ();
  Alcotest.run "retained verifier execution" ["execution",[
    Alcotest.test_case "worker returns its loaded original after an owner replacement" `Quick test_worker_returns_its_loaded_original;
    Alcotest.test_case "frozen prompt, media, lookup and verdict" `Quick test_frozen_prompt_media_and_lookup;
    Alcotest.test_case "missing and changed authority refuse before dispatch" `Quick test_refusals_dispatch_nothing;
    Alcotest.test_case "retry keeps both immutable originals" `Quick test_known_retry_preserves_frozen_original;
    Alcotest.test_case "bound scope plus definite pre-dispatch failure can retry safely" `Quick test_bound_scope_before_dispatch_failure_has_safe_retry;
    Alcotest.test_case "unknown and cancellation never redispatch" `Quick test_unknown_and_cancelled_never_redispatch;
    Alcotest.test_case "actual host commit and restart" `Quick test_actual_host_commit_restart;
    Alcotest.test_case "rejection commit is confirmed by its relation after a producer handoff edit" `Quick test_reject_commit_is_confirmed_by_its_relation;
    Alcotest.test_case "actual host recovers cancellation after domain write" `Quick test_actual_host_commit_cancel_after_domain_write;
    Alcotest.test_case "Judged recovery precedes actual preparation" `Quick test_judgment_recovery_precedes_actual_preparation;
    Alcotest.test_case "commit unknown recovers original" `Quick test_commit_unknown_recovers_exact_original;
    Alcotest.test_case "actual inner walk respects retained disposition" `Quick test_actual_inner_walk_respects_retained_disposition;
    Alcotest.test_case "pre-admission configuration repair reuses original" `Quick test_pre_admission_configuration_reenters_same_original;
    Alcotest.test_case "calibration uses the original on re-admission" `Quick test_calibration_uses_original_on_readmission;
    Alcotest.test_case "invalid inventory refuses allocation" `Quick test_bad_inventory_is_not_partial_authority;
    Alcotest.test_case "Judged boot preserves terminal operator authority" `Quick test_judged_boot_respects_terminal_operator;
    Alcotest.test_case "actual typed refusal race never reapplies" `Quick test_actual_before_apply_authority_race;
    Alcotest.test_case "atomic judgment observation survives unconfirmed publication" `Quick test_atomic_judgment_observation_unconfirmed;
    Alcotest.test_case "terminal publication cancellation recovers without Task or retained projection" `Quick test_terminal_publication_cancel_then_boot_without_task;
    Alcotest.test_case "post-atomic observation cancellation recovers through actual host" `Quick test_atomic_observation_cancel_then_actual_host;
    Alcotest.test_case "unpublishable original cannot starve a healthy boot publication" `Quick test_one_unpublishable_original_does_not_starve_boot;
    Alcotest.test_case "missing actual observer facts refuse before domain mutation" `Quick test_missing_observer_refuses_before_domain_mutation]]
