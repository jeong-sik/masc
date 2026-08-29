(** RFC-0387 stage 2 PR-2 — the goal verifier caller.

    The lane drains the ledger's durable pending requests
    ([Proof_pending]) through
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
   [on_tool_result]) and returned as the typed verdict, which carries the
   stated reason on either outcome. *)

type stub_behavior =
  | Stub_approve of string (* the model's stated reason *)
  | Stub_approve_silent (* a verdict with no stated reason *)
  | Stub_reject of string
  | Stub_malformed (* no verdict tool call *)
  | Stub_unavailable

let recording_reviewer calls behaviors =
  fun ~base_path:_ ?sw:_ ~evaluator_runtime ~prompt:_ ~report_tool_schema:_ ~lookup:_
      ~on_tool_result ~on_runtime_attempt_error:_ () ->
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
        (AR.Approve reason)
    | Some Stub_approve_silent ->
      answer (`Assoc [ "verdict", `String "APPROVE" ]) (AR.Approve "")
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
      (Masc_domain.completion_authority_kind verdict.Goal_verification.authority);
    (* The Keeper that asked for completion has to be able to learn the answer
       without going and looking for it. *)
    let announced =
      Workspace.get_all_messages_raw config ~since_seq:0
      |> List.exists (fun (message : Masc_domain.message) ->
        String_util.string_contains_substring
          ~needle:"[goal_verdict]"
          message.content
        && String_util.string_contains_substring ~needle:goal_id message.content
        && String_util.string_contains_substring
             ~needle:"all 3 services verified"
             message.content)
    in
    check bool "the verdict is announced to the workspace" true announced
  | _ -> fail "ledger must hold the proven verdict"
;;

(* The judge holds a read surface rooted at the shared playground, and it is
   built from the workspace alone. This goal has no linked Task and no
   producer of its own: the measurement is simply a file somebody wrote under
   the playground, and the judge reaches it by path. *)
let test_goal_proof_reads_the_workspace_playground () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Measured goal" in
  let playground = ensure_producer_playground config "some-keeper" in
  let artifact = Filename.concat playground "measurement.txt" in
  Out_channel.with_open_text artifact (fun channel ->
    output_string channel "pass rate: 100%\n");
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  let reads = ref 0 in
  (* One sentence, stated once: the tool call and the returned verdict must
     agree, the way a real reviewer's do. *)
  let stated_reason = "measured pass rate 100% reaches the target" in
  let reviewer =
    fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt ~report_tool_schema:_
        ~lookup ~on_tool_result ~on_runtime_attempt_error:_ () ->
      match lookup with
      | AR.No_lookup_surface ->
        fail "the Goal proof judge was handed no lookup surface"
      | AR.Lookup_tools { schemas; dispatch; root_layout } ->
        check bool "the read tool is advertised" true
          (List.exists
             (fun (schema : Masc_domain.tool_schema) ->
                String.equal schema.name "tool_read_file")
             schemas);
        check bool "the web tool is advertised" true
          (List.exists
             (fun (schema : Masc_domain.tool_schema) ->
                String.equal schema.name "masc_web_fetch")
             schemas);
        check bool "the prompt names the tools the judge holds" true
          (String_util.contains_substring prompt "tool_read_file");
        check bool "the prompt lists the root the tools resolve against" true
          (List.exists
             (fun entry -> String_util.contains_substring prompt entry)
             root_layout);
        let path = Filename.concat "some-keeper" "measurement.txt" in
        let read =
          dispatch
            ~name:"tool_read_file"
            ~args:(`Assoc [ "file_path", `String path ])
        in
        (match read with
         | Error detail -> fail ("the judge could not read the measurement: " ^ detail)
         | Ok output ->
           reads := !reads + 1;
           check bool "the judge read the measurement itself" true
             (String_util.contains_substring output "pass rate: 100%"));
        let input =
          `Assoc [ "verdict", `String "APPROVE"; "reason", `String stated_reason ]
        in
        on_tool_result
          ~input
          (Tool_result.ok ~tool_name:"report_review_verdict" ~start_time:0.0
             "recorded");
        Ok (Some (AR.Approve stated_reason))
  in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer
    (fun () -> drain config);
  check int "the judge performed one read" 1 !reads;
  check string "the measured goal completed" "completed" (stored_phase config goal_id)
;;

(* A refutation is not terminal. The goal goes back to Executing, the producer
   does the work the verdict said was missing, and the next request supersedes
   the standing refutation — no cooldown, no attempt counter, nothing that
   spends a goal's chances. The second review is judged on what it can read
   now, not on what the first one said. *)
let test_refuted_goal_can_request_proof_again_and_pass () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Goal that is measured on the second try" in
  let playground = ensure_producer_playground config "some-keeper" in
  let artifact = Filename.concat playground "measurement.txt" in
  let measured () = Sys.file_exists artifact in
  (* The judge here is honest about what it can see: it approves only when the
     measurement is actually on disk, and refuses otherwise. Nothing about the
     round trip is stubbed — the same reviewer answers both times. *)
  let verdicts = ref [] in
  let reviewer =
    fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_
        ~lookup ~on_tool_result ~on_runtime_attempt_error:_ () ->
      let dispatch =
        match lookup with
        | AR.Lookup_tools { dispatch; _ } -> dispatch
        | AR.No_lookup_surface -> fail "the judge was handed no lookup surface"
      in
      let read =
        dispatch
          ~name:"tool_read_file"
          ~args:
            (`Assoc
              [ "file_path", `String (Filename.concat "some-keeper" "measurement.txt") ])
      in
      let verdict, reason =
        match read with
        | Ok output when String_util.contains_substring output "pass rate: 100%" ->
          ( AR.Approve "read pass rate: 100%, which reaches the target"
          , "read pass rate: 100%, which reaches the target" )
        | Ok _ | Error _ ->
          ( AR.Reject "no measurement of the declared metric is on disk"
          , "no measurement of the declared metric is on disk" )
      in
      verdicts := !verdicts @ [ (match verdict with AR.Approve _ -> "approve" | AR.Reject _ -> "reject") ];
      on_tool_result
        ~input:
          (`Assoc
            [ "verdict"
            , `String (match verdict with AR.Approve _ -> "APPROVE" | AR.Reject _ -> "REJECT")
            ; "reason", `String reason
            ])
        (Tool_result.ok ~tool_name:"report_review_verdict" ~start_time:0.0 "recorded");
      Ok (Some verdict)
  in
  let review () =
    with_lane_and_reviewer
      ~slots:(fun () -> Ok [ "verifier-a" ])
      ~reviewer
      (fun () -> drain config)
  in
  (* First round: nothing measures the metric. *)
  check bool "nothing is measured yet" false (measured ());
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  review ();
  check string "the unmeasured goal is refused back to executing" "executing"
    (stored_phase config goal_id);
  (match (ledger_record config goal_id).completion with
   | Goal_verification.Proof_refuted _ -> ()
   | _ -> fail "the ledger must hold the refutation");

  (* The producer does the work the verdict named. *)
  Out_channel.with_open_text artifact (fun channel ->
    output_string channel "pass rate: 100%\n");

  (* Second round: the same request, now measurable. The new request must
     supersede the refutation in the ledger before any judge runs. *)
  ignore
    (must_succeed "request_complete again" (transition ctx goal_id "request_complete"));
  (match (ledger_record config goal_id).completion with
   | Goal_verification.Proof_pending _ -> ()
   | _ -> fail "the second request must leave the ledger pending, not refuted");
  review ();
  check (list string) "the same judge answered twice, differently"
    [ "reject"; "approve" ] !verdicts;
  check string "the measured goal completed on the retry" "completed"
    (stored_phase config goal_id);
  match (ledger_record config goal_id).completion with
  | Goal_verification.Proof_proven verdict ->
    check bool "the approval states what it measured" true
      (String_util.contains_substring verdict.Goal_verification.evidence
         "pass rate: 100%")
  | _ -> fail "the ledger must hold the proven verdict"
;;

(* Regression: the Goal proof root holds every producer, and the per-producer
   checkout scan stops on its reported-checkout budget (32) when walked across
   all of them. That stop is an [Error], so building the surface failed and the
   lane deferred without ever reaching the evaluator — every Goal review, on
   any workspace with enough checkouts. Observed live on a 38-producer
   workspace: "checkout budget exhausted (budget 32)", 0.85s, evaluator never
   reached (2026-08-23).

   This builds more checkouts than that budget and requires a verdict. *)
let test_goal_proof_surface_survives_a_crowded_playground () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Goal beside many producers" in
  let checkouts = 40 in
  for index = 0 to checkouts - 1 do
    let producer = Printf.sprintf "producer-%02d" index in
    let root = ensure_producer_playground config producer in
    let checkout = Filename.concat root "repo" in
    (try Unix.mkdir checkout 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    try Unix.mkdir (Filename.concat checkout ".git") 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  done;
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  let reached = ref false in
  let layout_seen = ref [] in
  let reviewer =
    fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_
        ~lookup ~on_tool_result ~on_runtime_attempt_error:_ () ->
      (match lookup with
       | AR.No_lookup_surface -> fail "the crowded root produced no lookup surface"
       | AR.Lookup_tools { root_layout; _ } -> layout_seen := root_layout);
      reached := true;
      on_tool_result
        ~input:
          (`Assoc
            [ "verdict", `String "REJECT"
            ; "reason", `String "no measurement of the declared metric was found"
            ])
        (Tool_result.ok ~tool_name:"report_review_verdict" ~start_time:0.0 "recorded");
      Ok (Some (AR.Reject "no measurement of the declared metric was found"))
  in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer
    (fun () -> drain config);
  check bool "the evaluator was reached rather than deferred" true !reached;
  check bool "every producer is listed, none dropped by a cap" true
    (List.length !layout_seen >= checkouts);
  check string "the review produced a verdict" "executing"
    (stored_phase config goal_id)
;;

(* (b) A refuted proof returns the goal to Executing; the reason is preserved
   in the ledger and in goal_events.jsonl. *)
let test_refuted_proof_returns_to_executing () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Refutable goal" in
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
         [ "verifier-a", Stub_reject "no measurement of the declared metric was found" ])
    (fun () -> drain config);
  check string "back to executing" "executing" (stored_phase config goal_id);
  (match (ledger_record config goal_id).completion with
   | Goal_verification.Proof_refuted
       { Goal_verification.outcome = Goal_verification.Refuted { reason }; _ } ->
     check string "the refutation reason is preserved"
       "no measurement of the declared metric was found" reason
   | _ -> fail "ledger must hold the refuted verdict");
  let events = goal_events_text config in
  check bool "the refutation reason reaches goal_events.jsonl" true
    (String_util.contains_substring events "no measurement of the declared metric was found")
;;

(* (c) A pending criterion check drains to a viable verdict — phase-neutral,
   the goal stays Executing. *)
(* (d) An unavailable evaluator is a typed non-verdict: the row stays
   pending, the phase stays Verifying, and the outcome names why. *)
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
            | Agent.Deferred reason ->
              check bool "the deferral states a reason" true
                (String.trim reason <> "")
            | Agent.Committed ->
              fail "an unavailable evaluator must not commit a verdict")
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
    [ "verifier-a"; "verifier-b" ]
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
  (* Simulate the crash window: the phase is Verifying but the ledger never
     recorded the proof request. *)
  (match
     Goal_store.upsert_goal config ~id:goal_id ~phase:Goal_phase.Verifying ()
   with
   | Ok _ -> ()
   | Error msg -> fail msg);
  (* Creation writes no ledger row, so the wedge starts with none at all —
     the same hole the scan re-arms, reached without a row to empty. *)
  (match Goal_verification.get_record config ~goal_id with
   | Ok None -> ()
   | Ok (Some _) -> fail "test setup: the wedge needs no durable request"
   | Error msg -> fail msg);
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
  List.exists (fun item -> String.equal item.Agent.goal_id goal_id) work
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
        ; test_case "goal proof reads the workspace playground" `Quick
            test_goal_proof_reads_the_workspace_playground
        ; test_case "a refuted goal can request proof again and pass" `Quick
            test_refuted_goal_can_request_proof_again_and_pass
        ; test_case "goal proof surface survives a crowded playground" `Quick
            test_goal_proof_surface_survives_a_crowded_playground
        ; test_case "refuted proof returns to executing with reason" `Quick
            test_refuted_proof_returns_to_executing
        ] )
    ; ( "non-verdicts keep evidence"
      , [ test_case "lane unavailable keeps the pending row" `Quick
            test_lane_unavailable_keeps_the_pending_row
        ; test_case "malformed reply fails over to the next slot" `Quick
            test_malformed_reply_fails_over_to_the_next_slot
        ; test_case "all slots failed keeps the pending row" `Quick
            test_all_slots_failed_keeps_the_pending_row
        ; test_case "approve without a stated reason does not commit" `Quick
            test_approve_without_a_stated_reason_does_not_commit
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
