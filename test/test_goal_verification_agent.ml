(** RFC-0387 stage 2 PR-2 — the goal verifier caller.

    The lane drains the ledger's durable pending requests
    ([Criterion_pending] / [Proof_pending]) through
    [Task.Anti_rationalization.review] on the stubbed verifier_exact lane and
    commits verdicts via the application-owned typed boundary, under the fixed
    identity [verifier_exact]. Typed non-verdicts (evaluator
    unavailable, malformed replies after all slots failed, a verdict without
    a stated reason) leave the pending row durable and schedule a retry —
    failure never consumes a pending row. *)

open Alcotest
open Masc
open Workspace_types

module AR = Task.Anti_rationalization
module Agent = Goal_verification_agent.For_testing

let temp_dir () =
  let path = Filename.temp_file "goal_verification_agent_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path)
      else Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let configure_prompt_registry () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts")
;;

let ensure_producer_playground (config : Workspace.config) producer =
  let path =
    Keeper_sandbox_config.host_root_abs_of_agent
      ~base_path:
        (Workspace_verification_store.project_root_of_base_path config.base_path)
      ~agent_name:producer
  in
  let rec mkdir_p dir =
    if not (Sys.file_exists dir)
    then (
      mkdir_p (Filename.dirname dir);
      try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  mkdir_p path;
  path
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Workspace.default_config dir in
       ignore (Workspace.init config ~agent_name:(Some "planner"));
       ignore (ensure_producer_playground config "unassigned");
       f config)
;;

let with_verification_persistence f =
  let previous = Atomic.get Workspace_hooks.verification_submit_request_fn in
  Atomic.set
    Workspace_hooks.verification_submit_request_fn
    (fun _config ~task:_ ~assignee:_ ~verification_id:_ ~evidence_refs:_ -> Ok ());
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.verification_submit_request_fn previous)
    f
;;

let workspace_ctx ?(agent_name = "planner") config : Tool_workspace.context =
  { Tool_workspace.config; agent_name }
;;

let dispatch ctx ~name args =
  match Tool_workspace.dispatch ctx ~name ~args:(`Assoc args) with
  | Some result -> result
  | None -> fail (name ^ " not handled")
;;

let body_of result = Yojson.Safe.from_string (Tool_result.message result)

let must_succeed label result =
  if Tool_result.is_success result
  then body_of result
  else
    fail (Printf.sprintf "%s: expected success, got %s" label (Tool_result.message result))
;;

let json_state json path =
  List.fold_left
    (fun acc key -> Yojson.Safe.Util.member key acc)
    json path
  |> Yojson.Safe.Util.to_string
;;

let create_goal ctx title =
  let created =
    must_succeed
      "create goal"
      (dispatch
         ctx
         ~name:"masc_goal_upsert"
         [ "title", `String title
         ; "metric", `String "verified services"
         ; "target_value", `String "3"
         ])
  in
  json_state created [ "goal_id" ]
;;

let producer_playground (config : Workspace.config) producer =
  ensure_producer_playground config producer
;;

(* A completion proof is admitted only when the Goal has a linked Task -- the
   rollup is the evidence and the performers are the trees. Tests that drive a
   proof verdict need one; they do not all need an artifact to read. *)
let link_bare_task config ~goal_id =
  let producer = "proof-producer" in
  ignore (ensure_producer_playground config producer);
  let created =
    match
      Workspace.add_task_with_result config ~goal_id ~created_by:producer
        ~title:"Linked proof task" ~priority:1 ~description:"proof evidence"
    with
    | Ok created -> created
    | Error error ->
      fail ("add linked task: " ^ Workspace.add_task_error_to_string error)
  in
  (match
     Workspace.claim_task_r config ~agent_name:producer ~task_id:created.task_id ()
   with
   | Ok _ -> ()
   | Error error -> fail (Masc_domain.masc_error_to_string error));
  created.task_id
;;

let add_linked_task_with_evidence config ~goal_id ~producer ~evidence_ref =
  let created =
    match
      Workspace.add_task_with_result
        config
        ~goal_id
        ~created_by:producer
        ~title:"Linked proof task"
        ~priority:1
        ~description:"Produce the Goal proof artifact"
    with
    | Ok created -> created
    | Error error ->
      fail
        ("add linked task: " ^ Workspace.add_task_error_to_string error)
  in
  (match Workspace.claim_task_r config ~agent_name:producer ~task_id:created.task_id () with
   | Ok _ -> ()
   | Error error -> fail (Masc_domain.masc_error_to_string error));
  let handoff_context : Masc_domain.task_handoff_context =
    { summary = "proof artifact is ready"
    ; reason = None
    ; next_step = None
    ; failure_mode = None
    ; reclaim_policy = None
    ; evidence_refs = [ evidence_ref ]
    ; updated_at = None
    ; updated_by = Some producer
    }
  in
  (match
     Workspace.transition_task_r
       config
       ~agent_name:producer
       ~task_id:created.task_id
       ~action:Masc_domain.Start
       ()
   with
   | Ok _ -> ()
   | Error error -> fail (Masc_domain.masc_error_to_string error));
  (match
     Workspace.transition_task_r
       config
       ~agent_name:producer
       ~task_id:created.task_id
       ~action:Masc_domain.Submit_for_verification
       ~notes:"artifact ready for Goal verification"
       ~handoff_context
       ()
   with
   | Ok _ -> ()
   | Error error -> fail (Masc_domain.masc_error_to_string error));
  created.task_id
;;

let transition ctx goal_id ?note ?evidence action =
  let args =
    [ "goal_id", `String goal_id; "action", `String action ]
    @ (match note with
       | Some note -> [ "note", `String note ]
       | None -> [])
    @ (match evidence with
       | Some evidence -> [ "evidence", `String evidence ]
       | None -> [])
  in
  dispatch ctx ~name:"masc_goal_transition" args
;;

let stored_phase config goal_id =
  match Goal_store.get_goal config ~goal_id with
  | Some goal -> Goal_phase.to_string goal.Goal_store.phase
  | None -> fail ("goal not found: " ^ goal_id)
;;

let ledger_record config goal_id =
  match Goal_verification.get_record config ~goal_id with
  | Ok (Some record) -> record
  | Ok None -> fail ("no ledger row for " ^ goal_id)
  | Error msg -> fail msg
;;

let goal_events_text config =
  let path =
    Filename.concat
      (Filename.dirname (Goal_verification.verifications_path config))
      "goal_events.jsonl"
  in
  if Sys.file_exists path
  then (
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let b = Buffer.create 256 in
         (try
            while true do
              Buffer.add_string b (input_line ic);
              Buffer.add_char b '\n'
            done
          with
          | End_of_file -> ());
         Buffer.contents b))
  else ""
;;

(* {1 Reviewer stubs}

   The stub plays the real reviewer's seam contract: a verdict is delivered
   by one successful [report_review_verdict] tool call (reported through
   [on_tool_result], which is where the lane reads the stated reason an
   APPROVE otherwise drops) and returned as the typed verdict. *)

type stub_behavior =
  | Stub_approve of string (* the model's stated reason *)
  | Stub_approve_silent (* a verdict with no stated reason *)
  | Stub_reject of string
  | Stub_malformed (* no verdict tool call *)
  | Stub_unavailable

let recording_reviewer calls behaviors =
  fun ~base_path:_ ?sw:_ ~evaluator_runtime ~prompt:_ ~report_tool_schema:_ ~lookup:_
      ~on_tool_result () ->
    calls := !calls @ [ evaluator_runtime ];
    let answer verdict_json verdict =
      on_tool_result
        ~input:verdict_json
        (Tool_result.ok ~tool_name:"report_review_verdict" ~start_time:0.0 "recorded");
      Ok (Some verdict)
    in
    match List.assoc_opt evaluator_runtime behaviors with
    | Some (Stub_approve reason) ->
      answer
        (`Assoc [ "verdict", `String "APPROVE"; "reason", `String reason ])
        AR.Approve
    | Some Stub_approve_silent ->
      answer (`Assoc [ "verdict", `String "APPROVE" ]) AR.Approve
    | Some (Stub_reject reason) ->
      answer
        (`Assoc [ "verdict", `String "REJECT"; "reason", `String reason ])
        (AR.Reject reason)
    | Some Stub_malformed -> Ok None
    | Some Stub_unavailable ->
      Error
        (Agent_core.Error.Api
           (Agent_core.Retry.ServerError
              { status = 503; message = "test evaluator unavailable" }))
    | None ->
      Error (Agent_core.Error.Internal ("unexpected evaluator slot " ^ evaluator_runtime))
;;

let inspecting_goal_reviewer ~producer ~file_name ~expected ~forest_reads =
  fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt ~report_tool_schema:_
      ~lookup ~on_tool_result () ->
    let report reason =
      let input =
        `Assoc [ "verdict", `String "APPROVE"; "reason", `String reason ]
      in
      on_tool_result
        ~input
        (Tool_result.ok
           ~tool_name:"report_review_verdict"
           ~start_time:0.0
           "recorded");
      Ok (Some AR.Approve)
    in
    match lookup with
    (* The creation-time criterion review gets no tree: it judges the declared
       success condition, and at creation nobody has produced anything for it.
       A Goal names no responsible keeper, so there is no single producer whose
       tree could stand in. *)
    | AR.No_lookup_surface -> report "criterion is measurable"
    | AR.Lookup_tools { scope = AR.Producer_tree; _ } ->
      fail
        "Goal review was handed a single-producer tree; a Goal has no single \
         producer"
    | AR.Lookup_tools
        { schemas
        ; dispatch
        ; scope = AR.Producer_forest { producers }
        } ->
      check (list string) "closed producer set" [ producer ] producers;
      check bool "rollup identifies the evidence producer" true
        (String_util.contains_substring
           prompt
           (Printf.sprintf "\"producer\": \"%s\"" producer));
      check bool "forest read tool is advertised" true
        (List.exists
           (fun (schema : Masc_domain.tool_schema) ->
              String.equal schema.name "verification_read_file")
           schemas);
      let input =
        `Assoc
          [ "producer", `String producer
          ; "file_path", `String file_name
          ]
      in
      (match dispatch ~name:"verification_read_file" ~args:input with
       | Error detail -> fail ("Goal proof lookup failed: " ^ detail)
       | Ok output ->
         check bool "Goal verifier read the linked producer artifact" true
           (String_util.contains_substring output expected);
         forest_reads := !forest_reads + 1;
         on_tool_result
           ~input
           (Tool_result.ok
              ~tool_name:"verification_read_file"
              ~start_time:0.0
              output));
      report "linked producer artifact was inspected"
;;

let with_lane_and_reviewer ~slots ~reviewer f =
  let saved_slots = Atomic.get Workspace_hooks.get_verifier_exact_lane_slot_ids_fn in
  let saved_reviewer = Atomic.get AR.run_llm_reviewer_fn in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.get_verifier_exact_lane_slot_ids_fn saved_slots;
      Atomic.set AR.run_llm_reviewer_fn saved_reviewer)
    (fun () ->
       Atomic.set Workspace_hooks.get_verifier_exact_lane_slot_ids_fn slots;
       Atomic.set AR.run_llm_reviewer_fn reviewer;
       f ())
;;

let drain config =
  match Agent.drain_once config with
  | Ok () -> ()
  | Error msg -> fail ("drain_once: " ^ msg)
;;

(* (a) A pending proof drains to a proven verdict: the goal completes, the
   ledger carries the fixed verifier identity and the model's stated reason
   as evidence. *)
let test_proof_pending_drains_to_completed () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Provable goal" in
  ignore (link_bare_task config ~goal_id);
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  check string "the durable request stands" "proof_pending"
    (match (ledger_record config goal_id).completion with
     | Goal_verification.Proof_pending _ -> "proof_pending"
     | _ -> "other");
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:(recording_reviewer (ref []) [ "verifier-a", Stub_approve "all 3 services verified" ])
    (fun () -> drain config);
  check string "goal completed via the drained proof" "completed"
    (stored_phase config goal_id);
  match (ledger_record config goal_id).completion with
  | Goal_verification.Proof_proven verdict ->
    check string "the model's stated reason is the evidence"
      "all 3 services verified" verdict.Goal_verification.evidence;
    check string "the fixed lane identity is the authority" "verifier_exact"
      (Masc_domain.completion_authority_actor verdict.Goal_verification.authority);
    check string "authority kind is the system-llm slot" "system_llm_agent"
      (Masc_domain.completion_authority_kind verdict.Goal_verification.authority)
  | _ -> fail "ledger must hold the proven verdict"
;;

(* A Goal with no linked Task carries no evidence: the rollup is empty and no
   performer tree exists. Its metric and target are the CLAIM under review, so
   admitting the review would let the judge approve the claim by reading the
   claim. The request is not consumed -- it stays pending, and the first linked
   Task makes the next drain admissible. *)
let test_proof_without_a_linked_task_is_not_judged () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Goal with nothing linked" in
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  let calls = ref [] in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:(recording_reviewer calls [ "verifier-a", Stub_approve "looks done" ])
    (fun () -> drain config);
  (* One call, and it is the creation-time criterion check -- that one is
     legitimately about the declared condition. The proof is never handed to an
     evaluator, so the claim is never rated against itself. *)
  check (list string) "only the criterion was judged, never the proof"
    [ "verifier-a" ] !calls;
  check string "the goal stays in verifying" "verifying" (stored_phase config goal_id);
  check string "the durable proof request survives" "proof_pending"
    (match (ledger_record config goal_id).completion with
     | Goal_verification.Proof_pending _ -> "proof_pending"
     | Goal_verification.Proof_proven _ -> "proof_proven"
     | Goal_verification.Proof_refuted _ -> "proof_refuted"
     | Goal_verification.Completion_idle -> "idle");
  (* Linking a Task makes the same request admissible on the next drain. *)
  ignore (link_bare_task config ~goal_id);
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:(recording_reviewer (ref []) [ "verifier-a", Stub_approve "task evidence holds" ])
    (fun () -> drain config);
  check string "with evidence the same request completes" "completed"
    (stored_phase config goal_id)
;;

let test_goal_proof_reads_linked_task_producer_artifact () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Artifact-inspected goal" in
  let producer = "builder" in
  let file_name = "artifacts/goal-proof.txt" in
  let playground = producer_playground config producer in
  let artifact_path = Filename.concat playground file_name in
  let artifact_dir = Filename.dirname artifact_path in
  if not (Sys.file_exists artifact_dir) then Unix.mkdir artifact_dir 0o755;
  Out_channel.with_open_text artifact_path (fun channel ->
    output_string channel "three services verified by isolated run\n");
  ignore
    (with_verification_persistence (fun () ->
       add_linked_task_with_evidence
         config
         ~goal_id
         ~producer
         ~evidence_ref:("artifact:" ^ file_name)));
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  let forest_reads = ref 0 in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:
      (inspecting_goal_reviewer
         ~producer
         ~file_name
         ~expected:"three services verified"
         ~forest_reads)
    (fun () -> drain config);
  check int "the proof review performed one linked-tree read" 1 !forest_reads;
  check string "inspected proof completed the Goal" "completed"
    (stored_phase config goal_id);
  let proof_runs =
    Goal_verification_run_registry.list_runs
      (Goal_verification_run_registry.global ())
    |> List.filter (fun run ->
      String.equal run.Goal_verification_run_registry.goal_id goal_id
      &&
      match run.review_kind with
      | Goal_verification_run_registry.Proof -> true
      | Goal_verification_run_registry.Criterion -> false)
  in
  match proof_runs with
  | [ { Goal_verification_run_registry.run_id
      ; status =
          Goal_verification_run_registry.Completed
            { outcome = Goal_verification_run_registry.Committed; tools; _ }
      ; _
      } ] ->
    (match (ledger_record config goal_id).completion with
     | Goal_verification.Proof_proven verdict ->
       check string "ledger verdict joins the exact Dashboard run" run_id
         verdict.Goal_verification.verification_run_id
     | _ -> fail "Goal proof ledger did not retain a proven verdict");
    check bool "Dashboard run retains the artifact read" true
      (List.exists
         (fun (tool : Verification_run_registry.tool_observation) ->
            String.equal tool.tool_name "verification_read_file")
         tools)
  | _ -> fail "Goal proof run was not durably projected as committed"
;;

(* (b) A refuted proof returns the goal to Executing; the reason is preserved
   in the ledger and in goal_events.jsonl. *)
let test_refuted_proof_returns_to_executing () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Refutable goal" in
  ignore (link_bare_task config ~goal_id);
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:
      (recording_reviewer
         (ref [])
         [ "verifier-a", Stub_approve "criterion is measurable" ])
    (fun () -> drain config);
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:
      (recording_reviewer
         (ref [])
         [ "verifier-a", Stub_reject "rollup shows 1 of 3 services verified" ])
    (fun () -> drain config);
  check string "back to executing" "executing" (stored_phase config goal_id);
  (match (ledger_record config goal_id).completion with
   | Goal_verification.Proof_refuted
       { Goal_verification.outcome = Goal_verification.Refuted { reason }; _ } ->
     check string "the refutation reason is preserved"
       "rollup shows 1 of 3 services verified" reason
   | _ -> fail "ledger must hold the refuted verdict");
  let events = goal_events_text config in
  check bool "the refutation reason reaches goal_events.jsonl" true
    (String_util.contains_substring events "rollup shows 1 of 3 services verified")
;;

(* (c) A pending criterion check drains to a viable verdict — phase-neutral,
   the goal stays Executing. *)
let test_criterion_pending_drains_to_viable () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Checked goal" in
  (match (ledger_record config goal_id).criterion with
   | Goal_verification.Criterion_pending _ -> ()
   | _ -> fail "creation must record the durable criterion request");
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:
      (recording_reviewer (ref []) [ "verifier-a", Stub_approve "criterion is measurable" ])
    (fun () -> drain config);
  check string "the goal is unmoved" "executing" (stored_phase config goal_id);
  match (ledger_record config goal_id).criterion with
  | Goal_verification.Criterion_viable verdict ->
    check string "the model's stated reason is the evidence"
      "criterion is measurable" verdict.Goal_verification.evidence
  | _ -> fail "ledger must hold the viable verdict"
;;

(* (d) An unavailable evaluator is a typed non-verdict: the row stays
   pending, the phase stays Verifying, and the outcome schedules a retry. *)
let test_lane_unavailable_keeps_the_pending_row () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Goal beside an unavailable lane" in
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:(recording_reviewer (ref []) [ "verifier-a", Stub_unavailable ])
    (fun () ->
       let work =
         match Agent.collect_pending config with
         | Ok work -> work
         | Error msg -> fail msg
       in
       let outcomes = List.map (Agent.process_pending_work config) work in
       List.iter
         (fun outcome ->
            match outcome with
            | Agent.Deferred { retryable = true; reason = _ } ->
              check bool "retry scheduled for a retryable deferral" true
                (Agent.should_schedule_retry outcome)
            | _ -> fail "an unavailable evaluator must defer retryable")
         outcomes);
  check string "the phase never left verifying" "verifying"
    (stored_phase config goal_id);
  match (ledger_record config goal_id).completion with
  | Goal_verification.Proof_pending _ -> ()
  | _ -> fail "failure must not consume the pending row"
;;

(* (e) A malformed reply fails over to the next slot in frozen declaration
   order; when every slot fails, the row stays pending. *)
let test_malformed_reply_fails_over_to_the_next_slot () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Failover goal" in
  ignore (link_bare_task config ~goal_id);
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  let calls = ref [] in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a"; "verifier-b" ])
    ~reviewer:
      (recording_reviewer
         calls
         [ "verifier-a", Stub_malformed
         ; "verifier-b", Stub_approve "second slot proved it"
         ])
    (fun () -> drain config);
  check (list string) "failover follows the declared slot order"
    (* The creation-time criterion check drains in the same scan and also
       fails over, so the attempt log reads [a; b] per review. *)
    [ "verifier-a"; "verifier-b"; "verifier-a"; "verifier-b" ]
    !calls;
  check string "the second slot's verdict completed the goal" "completed"
    (stored_phase config goal_id)
;;

let test_all_slots_failed_keeps_the_pending_row () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Exhausted lane goal" in
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  let calls = ref [] in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a"; "verifier-b" ])
    ~reviewer:
      (recording_reviewer
         calls
         [ "verifier-a", Stub_malformed; "verifier-b", Stub_malformed ])
    (fun () -> drain config);
  check (list string) "every slot was tried for the blocking criterion"
    [ "verifier-a"; "verifier-b" ]
    !calls;
  check string "the phase never left verifying" "verifying"
    (stored_phase config goal_id);
  match (ledger_record config goal_id).completion with
  | Goal_verification.Proof_pending _ -> ()
  | _ -> fail "all-slots-fail must not consume the pending row"
;;

let test_unreachable_criterion_blocks_the_pending_proof () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Unreachable criterion goal" in
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  let calls = ref [] in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:
      (recording_reviewer
         calls
         [ "verifier-a", Stub_reject "metric cannot be measured" ])
    (fun () -> drain config);
  check (list string) "proof reviewer was never called"
    [ "verifier-a" ] !calls;
  (match (ledger_record config goal_id).criterion with
   | Goal_verification.Criterion_unreachable _ -> ()
   | _ -> fail "criterion must hold the unreachable verdict");
  (match (ledger_record config goal_id).completion with
   | Goal_verification.Proof_pending _ -> ()
   | _ -> fail "blocked proof must remain durable");
  check string "proof cannot complete the goal" "verifying"
    (stored_phase config goal_id)
;;

let test_group_pending_orders_criterion_before_proof () =
  let proof : Agent.pending_work =
    { goal_id = "goal-a"; kind = Agent.Completion_proof }
  in
  let criterion : Agent.pending_work =
    { goal_id = "goal-a"; kind = Agent.Criterion_check }
  in
  match Agent.group_pending_by_goal [ proof; criterion ] with
  | [ [ { Agent.kind = Agent.Criterion_check; _ }
        ; { Agent.kind = Agent.Completion_proof; _ }
        ] ] -> ()
  | _ -> fail "one goal worker must run criterion before proof"
;;

(* (f) An APPROVE without the model's stated reason is not a judgment:
   nothing commits and the row stays pending. *)
let test_approve_without_a_stated_reason_does_not_commit () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Silent verdict goal" in
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:(recording_reviewer (ref []) [ "verifier-a", Stub_approve_silent ])
    (fun () -> drain config);
  check string "no commit without evidence" "verifying"
    (stored_phase config goal_id);
  match (ledger_record config goal_id).completion with
  | Goal_verification.Proof_pending _ -> ()
  | _ -> fail "a reasonless verdict must not consume the pending row"
;;

(* (g) The P0-2 cross-check: a goal stuck in Verifying whose ledger row lost
   the durable proof request is re-armed during the scan and drained in the
   same pass. *)
let test_verifying_goal_with_a_missing_request_is_rearmed_and_drained () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Wedged goal" in
  ignore (link_bare_task config ~goal_id);
  (* Simulate the crash window: the phase is Verifying but the ledger never
     recorded the proof request. *)
  (match
     Goal_store.upsert_goal config ~id:goal_id ~phase:Goal_phase.Verifying ()
   with
   | Ok _ -> ()
   | Error msg -> fail msg);
  (match (ledger_record config goal_id).completion with
   | Goal_verification.Completion_idle -> ()
   | _ -> fail "test setup: the wedge needs an idle ledger");
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:
      (recording_reviewer (ref []) [ "verifier-a", Stub_approve "verified after re-arm" ])
    (fun () -> drain config);
  check string "the re-armed gate completes" "completed"
    (stored_phase config goal_id);
  match (ledger_record config goal_id).completion with
  | Goal_verification.Proof_proven verdict ->
    check string "the verdict rode the re-armed request" "verified after re-arm"
      verdict.Goal_verification.evidence
  | _ -> fail "ledger must hold the proven verdict"
;;

let set_up_committed_proof_crash config ~outcome ~evidence =
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Crash-between-writes goal" in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:
      (recording_reviewer (ref []) [ "verifier-a", Stub_approve "criterion viable" ])
    (fun () -> drain config);
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  let verdict : Goal_verification.verdict =
    { outcome
    ; verification_run_id = "goal-run-before-crash"
    ; authority =
        Masc_domain.System_llm_agent { agent_run_id = "verifier_exact" }
    ; evidence
    ; recorded_at = Masc_domain.now_iso ()
    }
  in
  (match Goal_verification.record_proof_verdict config ~goal_id verdict with
   | Ok _ -> ()
   | Error msg -> fail msg);
  check string "test setup leaves the phase write missing" "verifying"
    (stored_phase config goal_id);
  goal_id
;;

let has_completion_work goal_id work =
  List.exists
    (fun item ->
       String.equal item.Agent.goal_id goal_id
       && item.kind = Agent.Completion_proof)
    work
;;

let test_committed_proven_proof_reconciles_without_review () =
  with_workspace
  @@ fun config ->
  let goal_id =
    set_up_committed_proof_crash
      config
      ~outcome:Goal_verification.Proven
      ~evidence:"artifact was inspected before the crash"
  in
  let work =
    match Agent.collect_pending config with
    | Ok work -> work
    | Error msg -> fail msg
  in
  check bool "reconciliation does not call the model again" false
    (has_completion_work goal_id work);
  check string "proven verdict converges to completed" "completed"
    (stored_phase config goal_id);
  match (ledger_record config goal_id).completion with
  | Goal_verification.Proof_proven verdict ->
    check string "the exact run survives reconciliation" "goal-run-before-crash"
      verdict.Goal_verification.verification_run_id
  | _ -> fail "reconciliation rewrote the proven ledger state"
;;

let test_committed_refuted_proof_reconciles_without_rearm () =
  with_workspace
  @@ fun config ->
  let goal_id =
    set_up_committed_proof_crash
      config
      ~outcome:(Goal_verification.Refuted { reason = "artifact contradicts claim" })
      ~evidence:"artifact contradicts claim"
  in
  let work =
    match Agent.collect_pending config with
    | Ok work -> work
    | Error msg -> fail msg
  in
  check bool "refutation is not overwritten by a re-armed request" false
    (has_completion_work goal_id work);
  check string "refuted verdict converges to executing" "executing"
    (stored_phase config goal_id);
  match (ledger_record config goal_id).completion with
  | Goal_verification.Proof_refuted verdict ->
    check string "the exact refutation run survives" "goal-run-before-crash"
      verdict.Goal_verification.verification_run_id
  | _ -> fail "reconciliation overwrote the refuted ledger state"
;;

let () =
  configure_prompt_registry ();
  run
    "goal_verification_agent"
    [ ( "drain"
      , [ test_case "proof pending drains to completed" `Quick
            test_proof_pending_drains_to_completed
        ; test_case "proof without a linked Task is not judged" `Quick
            test_proof_without_a_linked_task_is_not_judged
        ; test_case
            "Goal proof reads linked Task producer artifact"
            `Quick
            test_goal_proof_reads_linked_task_producer_artifact
        ; test_case "refuted proof returns to executing with reason" `Quick
            test_refuted_proof_returns_to_executing
        ; test_case "criterion pending drains to viable" `Quick
            test_criterion_pending_drains_to_viable
        ] )
    ; ( "non-verdicts keep evidence"
      , [ test_case "lane unavailable keeps the pending row" `Quick
            test_lane_unavailable_keeps_the_pending_row
        ; test_case "malformed reply fails over to the next slot" `Quick
            test_malformed_reply_fails_over_to_the_next_slot
        ; test_case "all slots failed keeps the pending row" `Quick
            test_all_slots_failed_keeps_the_pending_row
        ; test_case "unreachable criterion blocks the pending proof" `Quick
            test_unreachable_criterion_blocks_the_pending_proof
        ; test_case "approve without a stated reason does not commit" `Quick
            test_approve_without_a_stated_reason_does_not_commit
        ] )
    ; ( "scheduling"
      , [ test_case "groups criterion before proof per goal" `Quick
            test_group_pending_orders_criterion_before_proof
        ] )
    ; ( "re-arm"
      , [ test_case
            "committed proven proof reconciles without review"
            `Quick
            test_committed_proven_proof_reconciles_without_review
        ; test_case
            "committed refuted proof reconciles without re-arm"
            `Quick
            test_committed_refuted_proof_reconciles_without_rearm
        ; test_case "verifying goal with a missing request is rearmed and drained"
            `Quick
            test_verifying_goal_with_a_missing_request_is_rearmed_and_drained
        ] )
    ]
;;
