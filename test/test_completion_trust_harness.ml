(** Task-completion dispatch oracle.

    Lifecycle ownership remains deterministic. Once an owned task reaches the
    completion-quality boundary, only the configured LLM verdict decides:
    short notes and missing/untrusted evidence are prompt facts, evaluator
    rejection leaves the task active, and a later LLM approval completes it. *)

open Alcotest

module KET = Masc.Keeper_tool_dispatch_runtime
module KTE = Masc.Keeper_tool_execution
module Workspace = Masc.Workspace
module AR = Masc.Task.Anti_rationalization
module Publication_availability =
  Masc.Keeper_publication_recovery_availability

type reviewer_response =
  | Reviewer_verdict of AR.verdict
  | Reviewer_unavailable

let reviewer_response = ref (Reviewer_verdict AR.Approve)

let reviewer ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () =
  match !reviewer_response with
  | Reviewer_verdict verdict -> Ok (Some verdict)
  | Reviewer_unavailable ->
    Error (Agent_sdk.Error.Internal "test evaluator unavailable")
;;

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir path =
  let rec rm target =
    if Sys.file_exists target then
      if Sys.is_directory target then begin
        Sys.readdir target
        |> Array.iter (fun name -> rm (Filename.concat target name));
        Unix.rmdir target
      end
      else Unix.unlink target
  in
  try rm path with _ -> ()

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else begin
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let output = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output contents)

let make_meta ?(name = "keeper-completion-trust") () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ ("name", `String name)
        ; ("agent_name", `String name)
        ; ("trace_id", `String "completion-trust-harness-trace")
        ; ("allowed_paths", `List [ `String "*" ])
        ])
  with
  | Ok meta -> meta
  | Error err -> failwith ("make_meta failed: " ^ err)

let make_ctx () =
  Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
    ~max_tokens:4000

let with_ws name fn =
  let dir = temp_dir name in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run @@ fun sw ->
      let config = Masc.Workspace.default_config dir in
      let meta = make_meta () in
      ignore (Masc.Keeper_registry.register ~base_path:config.base_path meta.name meta);
      Fun.protect
        ~finally:(fun () ->
          Masc.Keeper_registry.unregister ~base_path:config.base_path meta.name)
        (fun () ->
          Masc_test_deps.with_publication_recovery_registry
            ~sw
            ~fs:(Eio.Stdenv.fs env)
            ~registry_root:dir
            (fun publication_recovery_registry ->
               let publication_recovery =
                 { Publication_availability.provider =
                     Masc_test_deps.publication_recovery_provider
                       publication_recovery_registry
                 ; keeper_name = meta.name
                 }
               in
               fn
                 ~config
                 ~meta
                 ~publication_recovery
                 ~ctx_work:(make_ctx ()))))

let outcome_label = function
  | Tool_result.Completed () -> "success"
  | Tool_result.Deferred () -> "deferred"
  | Tool_result.Failed _ -> "failure"

let parse_json raw =
  try Yojson.Safe.from_string raw with
  | Yojson.Json_error err -> fail ("invalid json: " ^ err)

let contains_substring text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop idx =
    idx + needle_len <= text_len
    && (String.sub text idx needle_len = needle || loop (idx + 1))
  in
  needle_len = 0 || loop 0

(* Owner of a task if it is currently Claimed/InProgress, else None. *)
let assignee_of config task_id =
  match
    List.find_opt
      (fun (t : Masc_domain.task) -> String.equal t.id task_id)
      (Workspace.get_tasks_raw config)
  with
  | Some
      { task_status =
          ( Masc_domain.Claimed { assignee; _ }
          | Masc_domain.InProgress { assignee; _ } )
      ; _
      } ->
    Some assignee
  | _ -> None

let attempt_done
      ?(evidence_refs = [ "trace:completion-trust-harness" ])
      ~config
      ~meta
      ~publication_recovery
      ~ctx_work
      ~task_id
      ~result
      ()
  =
  KET.execute_keeper_tool_call_with_outcome
    ~config
    ~meta
    ~publication_recovery
    ~ctx_work
    ~exec_cache:None
    ~name:"keeper_task_done"
    ~input:
      (`Assoc
        [ "task_id", `String task_id
        ; "result", `String result
        ; ( "evidence_refs"
          , `List (List.map (fun ref_ -> `String ref_) evidence_refs) )
        ])
    ()

let seed_trace_evidence ~config trace_id =
  let path =
    Filename.concat
      (Filename.concat
         (Filename.concat config.Workspace.base_path ".masc")
         "trajectories/keeper-completion-trust")
      (trace_id ^ ".jsonl")
  in
  write_file path
    {|{"type":"completion_trust_evidence","turn":0,"trace_id":"test"}|}

let claim_via_dispatch
      ~config
      ~meta
      ~publication_recovery
      ~ctx_work
      ~task_id
  =
  KET.execute_keeper_tool_call_with_outcome
    ~config
    ~meta
    ~publication_recovery
    ~ctx_work
    ~exec_cache:None
    ~name:"keeper_task_claim"
    ~input:(`Assoc [ ("task_id", `String task_id) ])
    ()

(* Test A — non-owner completion is denied (RFC-0262 axis-2 ownership gate). *)
let test_completion_denied_for_non_owner () =
  with_ws "completion_trust_non_owner"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.agent_name));
    ignore
      (Workspace.add_task config ~title:"foreign-owned task" ~priority:1
         ~description:"claimed by another agent");
    let foreign = "other-keeper" in
    (match Workspace.claim_task_r config ~agent_name:foreign ~task_id:"task-001" () with
     | Ok _ -> ()
     | Error e ->
       fail ("foreign claim setup failed: " ^ Masc_domain.masc_error_to_string e));
    (* pre-state: task-001 owned by a non-caller agent (else the reject below
       would be NotClaimed for the wrong reason). *)
    (match assignee_of config "task-001" with
     | Some a ->
       check bool "pre-state: task owned by a non-caller agent" true
         (not (String.equal a meta.agent_name))
     | None ->
       fail "task-001 must be Claimed/InProgress by the foreign agent before the attack");
    (* attack: caller (non-owner) tries to complete it, with substantive notes so
       the reject is unambiguously about ownership, not note length. *)
    let result =
      attempt_done ~config ~meta ~publication_recovery ~ctx_work
        ~task_id:"task-001"
        ~result:"I finished another agent's task on their behalf"
        ()
    in
    check string "non-owner completion outcome" "failure"
      (outcome_label result.KTE.disposition);
    let json = parse_json result.KTE.raw_output in
    check bool "rejection is ok=false" false Yojson.Safe.Util.(member "ok" json |> to_bool);
    check string "ownership reject is a deterministic workflow rejection" "workflow_rejection"
      Yojson.Safe.Util.(member "failure_class" json |> to_string);
    check string "ownership reject rule_id" "task_done_requires_current_owner"
      Yojson.Safe.Util.(member "diagnosis" json |> member "rule_id" |> to_string);
    (* anti-vacuity: the rejected attempt did NOT advance the FSM. *)
    (match assignee_of config "task-001" with
     | Some a ->
       check bool "task still owned by foreign agent after rejected completion" true
         (not (String.equal a meta.agent_name))
     | None -> fail "task-001 must remain Claimed/InProgress after the rejected completion"))

(* Test B — completion of an unclaimed (Todo) task is denied. *)
let test_completion_denied_when_unclaimed () =
  with_ws "completion_trust_unclaimed"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.agent_name));
    ignore
      (Workspace.add_task config ~title:"never claimed" ~priority:1
         ~description:"still in the backlog");
    (* task-001 is Todo; nobody claimed it. *)
    let result =
      attempt_done ~config ~meta ~publication_recovery ~ctx_work
        ~task_id:"task-001"
        ~result:"pretending an unclaimed backlog item is finished"
        ()
    in
    check string "unclaimed completion outcome" "failure"
      (outcome_label result.KTE.disposition);
    let json = parse_json result.KTE.raw_output in
    check string "unclaimed reject is a workflow rejection" "workflow_rejection"
      Yojson.Safe.Util.(member "failure_class" json |> to_string);
    check string "unclaimed reject rule_id" "task_done_requires_claimed_or_started"
      Yojson.Safe.Util.(member "diagnosis" json |> member "rule_id" |> to_string);
    (* anti-vacuity: task stays Todo. *)
    match
      List.find_opt
        (fun (t : Masc_domain.task) -> String.equal t.id "task-001")
        (Workspace.get_tasks_raw config)
    with
    | Some { task_status = Masc_domain.Todo; _ } -> ()
    | _ -> fail "task-001 must remain Todo after the rejected completion")

(* Local note length and evidence shape never decide completion. *)
let test_short_notes_without_evidence_follow_llm_approval () =
  with_ws "completion_llm_short_notes"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
    reviewer_response := Reviewer_verdict AR.Approve;
    ignore (Workspace.init config ~agent_name:(Some meta.agent_name));
    ignore
      (Workspace.add_task config ~title:"caller's own task" ~priority:1
         ~description:"the LLM reviews even a short completion claim");
    let claim =
      claim_via_dispatch ~config ~meta ~publication_recovery ~ctx_work
        ~task_id:"task-001"
    in
    check string "self-claim succeeds" "success"
      (outcome_label claim.KTE.disposition);
    let result =
      attempt_done
        ~config
        ~meta
        ~publication_recovery
        ~ctx_work
        ~task_id:"task-001"
        ~result:"done"
        ~evidence_refs:[]
        ()
    in
    check string "LLM approval controls outcome" "success"
      (outcome_label result.KTE.disposition);
    match
      List.find_opt
        (fun (task : Masc_domain.task) -> String.equal task.id "task-001")
        (Workspace.get_tasks_raw config)
    with
    | Some { task_status = Masc_domain.Done _; _ } -> ()
    | Some task ->
      fail
        ("expected Done after LLM approval, got "
         ^ Masc_domain.task_status_to_string task.task_status)
    | None -> fail "task-001 missing after completion")


let test_completion_with_evidence_refs_succeeds () =
  with_ws "completion_trust_evidence_refs"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
    reviewer_response := Reviewer_verdict AR.Approve;
    ignore (Workspace.init config ~agent_name:(Some meta.agent_name));
    ignore
      (Workspace.add_task config ~title:"complete with evidence refs" ~priority:1
         ~description:"claimed by the caller and completed with trusted proof");
    let claim =
      claim_via_dispatch ~config ~meta ~publication_recovery ~ctx_work
        ~task_id:"task-001"
    in
    check string "self-claim precondition succeeds" "success"
      (outcome_label claim.KTE.disposition);
    seed_trace_evidence ~config "completion-trust-harness";
    let result =
      attempt_done
        ~config
        ~meta
        ~publication_recovery
        ~ctx_work
        ~task_id:"task-001"
        ~result:"Implemented the deliverable and saved trace:completion-trust-harness evidence."
        ~evidence_refs:[ "trace:completion-trust-harness" ]
        ()
    in
    check string "completion outcome" "success"
      (outcome_label result.KTE.disposition);
    match
      List.find_opt
        (fun (t : Masc_domain.task) -> String.equal t.id "task-001")
        (Workspace.get_tasks_raw config)
    with
    | Some
        { task_status = Masc_domain.Done { assignee; _ }
        ; handoff_context = Some handoff
        ; _
        } ->
      check string "done assignee" meta.agent_name assignee;
      check (list string) "handoff evidence_refs" [ "trace:completion-trust-harness" ] handoff.evidence_refs
    | Some task ->
      fail
        ("expected task-001 Done with handoff evidence refs, got "
         ^ Masc_domain.task_status_to_string task.task_status)
    | None -> fail "task-001 missing after completion")

(* An LLM rejection leaves only this task active; a later approval can
   complete it without changing evidence shape. *)
let test_llm_rejection_keeps_task_active_then_approval_completes () =
  with_ws "completion_llm_reject_then_approve"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.agent_name));
    ignore
      (Workspace.add_task config ~title:"LLM reviewed completion" ~priority:1
         ~description:"completion follows the evaluator verdict");
    let claim =
      claim_via_dispatch ~config ~meta ~publication_recovery ~ctx_work
        ~task_id:"task-001"
    in
    check string "self-claim succeeds" "success"
      (outcome_label claim.KTE.disposition);
    reviewer_response := Reviewer_verdict (AR.Reject "deliverable is not complete");
    let rejected =
      attempt_done
        ~config
        ~meta
        ~publication_recovery
        ~ctx_work
        ~task_id:"task-001"
        ~result:"Completed the deliverable."
        ~evidence_refs:[ "arbitrary-unresolved-reference" ]
        ()
    in
    check string "LLM reject controls outcome" "failure"
      (outcome_label rejected.KTE.disposition);
    check bool "LLM reason is returned" true
      (contains_substring rejected.KTE.raw_output "deliverable is not complete");
    (match assignee_of config "task-001" with
     | Some assignee ->
       check string "task remains active for the same keeper"
         meta.agent_name assignee
     | None -> fail "rejected task must remain Claimed/InProgress");
    reviewer_response := Reviewer_verdict AR.Approve;
    let approved =
      attempt_done
        ~config
        ~meta
        ~publication_recovery
        ~ctx_work
        ~task_id:"task-001"
        ~result:"Completed the deliverable."
        ~evidence_refs:[ "arbitrary-unresolved-reference" ]
        ()
    in
    check string "later LLM approval completes" "success"
      (outcome_label approved.KTE.disposition);
    match
      List.find_opt
        (fun (task : Masc_domain.task) -> String.equal task.id "task-001")
        (Workspace.get_tasks_raw config)
    with
    | Some { task_status = Masc_domain.Done _; _ } -> ()
    | Some task ->
      fail
        ("expected Done after LLM approval, got "
         ^ Masc_domain.task_status_to_string task.task_status)
    | None -> fail "task-001 missing after approved retry")

let test_unavailable_evaluator_keeps_task_active () =
  with_ws "completion_llm_unavailable"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.agent_name));
    ignore
      (Workspace.add_task config ~title:"unavailable evaluator" ~priority:1
         ~description:"must stay active without an LLM verdict");
    let claim =
      claim_via_dispatch ~config ~meta ~publication_recovery ~ctx_work
        ~task_id:"task-001"
    in
    check string "self-claim succeeds" "success"
      (outcome_label claim.KTE.disposition);
    reviewer_response := Reviewer_unavailable;
    let result =
      attempt_done
        ~config
        ~meta
        ~publication_recovery
        ~ctx_work
        ~task_id:"task-001"
        ~result:"Completed the deliverable."
        ~evidence_refs:[]
        ()
    in
    check string "unavailable evaluator rejects" "failure"
      (outcome_label result.KTE.disposition);
    check bool "typed evaluator failure is visible" true
      (contains_substring result.KTE.raw_output "evaluator unavailable");
    match assignee_of config "task-001" with
    | Some assignee ->
      check string "only task remains active" meta.agent_name assignee
    | None -> fail "task must remain Claimed/InProgress")


(* Positive lifecycle control: a keeper claiming its own backlog task is
   accepted on the same dispatch path. *)
let test_legitimate_claim_succeeds () =
  with_ws "completion_trust_positive_claim"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.agent_name));
    ignore
      (Workspace.add_task config ~title:"claimable task" ~priority:1
         ~description:"unowned backlog work");
    let result =
      claim_via_dispatch ~config ~meta ~publication_recovery ~ctx_work
        ~task_id:"task-001"
    in
    check string "legitimate claim outcome" "success"
      (outcome_label result.KTE.disposition);
    match assignee_of config "task-001" with
    | Some assignee -> check string "claimed task is owned by the caller" meta.agent_name assignee
    | None -> fail "task-001 must be Claimed/InProgress after a legitimate claim")

let () =
  Masc_test_deps.init_keeper_tool_registry ();
  Atomic.set Workspace_hooks.get_default_runtime_id_fn (fun () -> "test-evaluator-runtime");
  Atomic.set AR.run_llm_reviewer_fn reviewer;
  run "Completion_trust_harness"
    [ ( "completion_trust_dispatch_oracle"
      , [ test_case "non-owner completion is denied (ownership gate)" `Quick
            test_completion_denied_for_non_owner
        ; test_case "completion of an unclaimed task is denied" `Quick
            test_completion_denied_when_unclaimed
        ; test_case "short notes without evidence follow LLM approval"
            `Quick test_short_notes_without_evidence_follow_llm_approval
        ; test_case "completion with evidence_refs succeeds"
            `Quick test_completion_with_evidence_refs_succeeds
        ; test_case "LLM reject keeps task active; approval completes"
            `Quick test_llm_rejection_keeps_task_active_then_approval_completes
        ; test_case "unavailable evaluator keeps task active"
            `Quick test_unavailable_evaluator_keeps_task_active
        ; test_case "legitimate self-claim is accepted (selectivity control)" `Quick
            test_legitimate_claim_succeeds
        ] )
    ]
