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

let lookup_text result =
  match result with
  | Tool_result.Completed _ -> Ok (Tool_result.message result)
  | Tool_result.Failed _ -> Error (Tool_result.message result)
  | Tool_result.Deferred _ -> Alcotest.fail "lookup unexpectedly deferred"
;;

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

(* A producer here is a workspace agent, not a Keeper: it declares no sandbox
   profile, and since #32078 the Keeper resolver raises rather than assuming
   one. [Verification_authority_tools.create] takes its [Workspace_producer]
   arm for such a producer and roots it at [bundle_root] under the shared
   playground prefix, which is also the prefix the Goal proof surface walks.
   Writing where the surface reads is the point of this helper; a path
   invented here would let the test pass while the product looked elsewhere. *)
let ensure_producer_playground (config : Workspace.config) producer =
  let path =
    Filename.concat
      (Workspace_verification_store.project_root_of_base_path config.base_path)
      (Playground_paths.bundle_root producer)
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

(* The clock of the running [with_workspace], for a test that must fail
   rather than hang when an awaited event never arrives. *)
let workspace_clock : float Eio.Time.clock_ty Eio.Resource.t option ref = ref None

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  workspace_clock := Some (Eio.Stdenv.clock env);
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
    (fun _config ~task:_ ~assignee:_ ~verification_id:_ ~claim:_ -> Ok ());
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
  match Goal_store.find_goal config ~goal_id with
  | Goal_store.Goal_found goal -> Goal_phase.to_string goal.Goal_store.phase
  | Goal_store.Goal_absent -> fail ("goal not found: " ^ goal_id)
  | Goal_store.Store_unavailable u -> fail (Goal_store.unavailable_to_string u)
;;

let ledger_record config goal_id =
  match Goal_verification.get_record config ~goal_id with
  | Ok (Some record) -> record
  | Ok None -> fail ("no ledger row for " ^ goal_id)
  | Error msg -> fail msg
;;

let pending_identity config goal_id =
  match (ledger_record config goal_id).completion with
  | Goal_verification.Proof_pending { request_id; criterion; _ } -> request_id, criterion
  | _ -> fail "expected pending proof identity"
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

let recording_reviewer ?(before_verdict = fun _prompt -> ()) calls behaviors =
  fun ~base_path:_ ?sw:_ ~evaluator_runtime ~prompt ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_
      ~on_tool_result ~on_runtime_attempt_error:_ () ->
    calls := !calls @ [ evaluator_runtime ];
    before_verdict prompt;
    let answer verdict_json verdict =
      on_tool_result
        ~input:verdict_json
        (Tool_result.ok ~tool_name:"report_review_verdict" ~start_time:0.0 "recorded");
      Ok {AR.selected_runtime_id=evaluator_runtime;verdict=Some verdict}
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
    | Some Stub_malformed -> Ok {AR.selected_runtime_id=evaluator_runtime;verdict=None}
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
  | Error failure -> fail ("drain_once: " ^ Agent.scan_failure_to_string failure)
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
  check string "goal completed via the drained proof" "awaiting_confirmation"
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
    fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt ?goal_blocks:_ ~report_tool_schema:_
        ~lookup ~on_tool_result ~on_runtime_attempt_error:_ () ->
      let { AR.schemas; dispatch } = lookup in
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
        (String_util.contains_substring prompt "some-keeper");
      let path = Filename.concat "some-keeper" "measurement.txt" in
      let read =
        dispatch
          ~name:"tool_read_file"
          ~args:(`Assoc [ "file_path", `String path ])
        |> lookup_text
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
      Ok {AR.selected_runtime_id="verifier-a";verdict=Some (AR.Approve stated_reason)}
  in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer
    (fun () -> drain config);
  check int "the judge performed one read" 1 !reads;
  check string "the measured goal completed" "awaiting_confirmation" (stored_phase config goal_id)
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
    fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ?goal_blocks:_ ~report_tool_schema:_
        ~lookup ~on_tool_result ~on_runtime_attempt_error:_ () ->
      let { AR.dispatch; _ } = lookup in
      let read =
        dispatch
          ~name:"tool_read_file"
          ~args:
            (`Assoc
              [ "file_path", `String (Filename.concat "some-keeper" "measurement.txt") ])
        |> lookup_text
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
      Ok {AR.selected_runtime_id="verifier-a";verdict=Some verdict}
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
  check string "the measured goal completed on the retry" "awaiting_confirmation"
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
  let prompt_seen = ref "" in
  let reviewer =
    fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt ?goal_blocks:_ ~report_tool_schema:_
        ~lookup:_ ~on_tool_result ~on_runtime_attempt_error:_ () ->
      prompt_seen := prompt;
      reached := true;
      on_tool_result
        ~input:
          (`Assoc
            [ "verdict", `String "REJECT"
            ; "reason", `String "no measurement of the declared metric was found"
            ])
        (Tool_result.ok ~tool_name:"report_review_verdict" ~start_time:0.0 "recorded");
      Ok {AR.selected_runtime_id="verifier-a";verdict=Some (AR.Reject "no measurement of the declared metric was found")}
  in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer
    (fun () -> drain config);
  check bool "the evaluator was reached rather than deferred" true !reached;
  check bool "every producer is listed, none dropped by a cap" true
    (List.for_all
       (fun index ->
          String_util.contains_substring
            !prompt_seen
            (Printf.sprintf "producer-%02d" index))
       (List.init checkouts Fun.id));
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
         | Ok { Agent.collected; _ } -> collected
         | Error failure -> fail (Agent.scan_failure_to_string failure)
       in
       let outcomes = List.map (Agent.process_pending_work config) work in
       List.iter
         (fun outcome ->
            match outcome with
            | Agent.Deferred reason ->
              check bool "the deferral states a reason" true
                (String.trim reason <> "")
            | Agent.Committed ->
              fail "an unavailable evaluator must not commit a verdict"
            | Agent.Superseded ->
              fail "an unchanged request cannot be superseded")
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
  check string "the second slot's verdict completed the goal" "awaiting_confirmation"
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
   | Error error -> fail (Goal_store.write_error_to_string error));
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
  check string "the re-armed gate completes" "awaiting_confirmation"
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
  let request_id, criterion = pending_identity config goal_id in
  let verdict : Goal_verification.verdict =
    { outcome
    ; request_id
    ; criterion
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

let reviews_of_goal registry goal_id =
  Goal_verification_run_registry.list_runs registry
  |> List.filter_map (function
    | Goal_verification_run_registry.Review (run : Goal_verification_run_registry.run)
      when String.equal run.goal_id goal_id -> Some run
    | Goal_verification_run_registry.Review _
    | Goal_verification_run_registry.Scan_skipped _ -> None)
;;

(* The skipped-scan rows this workspace's store produced. The registry is
   process-global, so rows are told apart by the file they name. *)
let skipped_scans_of_store path =
  Goal_verification_run_registry.list_runs (Goal_verification_run_registry.global ())
  |> List.filter_map (function
    | Goal_verification_run_registry.Scan_skipped { unavailable; _ }
      when String.equal unavailable.Goal_store.file path -> Some unavailable
    | Goal_verification_run_registry.Scan_skipped _
    | Goal_verification_run_registry.Review _ -> None)
;;

(* [since_seq] is exclusive and the ring's first entry carries seq 0. *)
let ring_cursor () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.Log.Ring.seq
  | [] -> -1
;;

let skipped_scan_lines_since cursor =
  Log.Ring.recent ~since_seq:cursor ~module_filter:"Misc" ~order:`Oldest_first ()
  |> List.filter (fun (entry : Log.Ring.entry) ->
    String.starts_with ~prefix:Goal_verification_agent.scan_skipped_log_prefix
      entry.message)
;;

(* goals.json as the 2026-09-08 hard cut left it: JSON, rows, no
   [criterion_revision]. The mirror written by the upsert still decodes. *)
let strip_criterion_revision path =
  let stripped =
    match Yojson.Safe.from_string (Fs_compat.load_file path) with
    | `Assoc members ->
      `Assoc
        (List.map
           (function
             | "goals", `List goals ->
               ( "goals"
               , `List
                   (List.map
                      (function
                        | `Assoc goal ->
                          `Assoc
                            (List.filter
                               (fun (key, _) -> not (String.equal key "criterion_revision"))
                               goal)
                        | other -> other)
                      goals) )
             | member -> member)
           members)
    | _ -> fail "goals.json is not an object"
  in
  Fs_compat.save_file path (Yojson.Safe.to_string stripped)
;;

(* RFC-0444 §2.3 row 7, criterion 3: every scan the store refuses leaves one
   durable [Scan_skipped] row carrying the typed value and exactly one WARN
   line that starts with the counted literal. Two cycles, two of each. *)
let test_skipped_scan_records_one_row_and_one_warn_per_cycle () =
  with_workspace @@ fun config ->
  (match Goal_store.upsert_goal config ~title:"Rows without criterion_revision"
      ~metric:"cases" ~target_value:"1" () with
   | Ok _ -> () | Error error -> fail (Goal_store.write_error_to_string error));
  let path = Goal_store.goals_path config in
  strip_criterion_revision path;
  let bytes = Fs_compat.load_file path in
  let mirror = Fs_compat.load_file (path ^ ".last-good") in
  let rows_before = List.length (skipped_scans_of_store path) in
  let cursor = ring_cursor () in
  let cycle () =
    match Agent.drain_once config with
    | Error (Agent.Scan_skipped { Goal_store.reason = Goal_store.Schema_rejected { field; _ }
                                ; reset_step = Goal_store.Repair_field repair; _ }) ->
      check string "the scan names the refused member" "criterion_revision" field;
      check string "the scan names the repair" "criterion_revision" repair
    | Error (Agent.Scan_skipped _) -> fail "the reason is not the refused schema member"
    | Ok () -> fail "rows without criterion_revision drained as a healthy store"
  in
  cycle ();
  cycle ();
  let rows = skipped_scans_of_store path in
  check int "one durable row per skipped scan" (rows_before + 2) (List.length rows);
  List.iter
    (fun (unavailable : Goal_store.unavailable) ->
       match unavailable.reason, unavailable.mirror with
       | Goal_store.Schema_rejected { field; _ }, Goal_store.Mirror_decodes { goal_count; _ } ->
         check string "the row keeps the refused member" "criterion_revision" field;
         check int "the row keeps the mirror evidence" 1 goal_count
       | _ -> fail "the row lost the reason or the mirror evidence")
    rows;
  check int "one WARN line per skipped scan" 2
    (List.length (skipped_scan_lines_since cursor));
  check string "the scan does not repair the primary" bytes (Fs_compat.load_file path);
  check string "the scan does not touch the mirror" mirror
    (Fs_compat.load_file (path ^ ".last-good"))
;;

let test_healthy_store_scan_records_no_skipped_row () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  ignore (create_goal ctx "Healthy store");
  let path = Goal_store.goals_path config in
  let cursor = ring_cursor () in
  drain config;
  check int "a readable store leaves no skipped-scan row" 0
    (List.length (skipped_scans_of_store path));
  check int "a readable store writes no skipped-scan line" 0
    (List.length (skipped_scan_lines_since cursor))
;;

let test_scan_preserves_source_failure () =
  with_workspace @@ fun config ->
  (match Goal_store.upsert_goal config ~title:"Review source"
      ~metric:"cases" ~target_value:"1" () with
   | Ok _ -> () | Error error -> fail (Goal_store.write_error_to_string error));
  let path = Goal_store.goals_path config in
  let mirror = Fs_compat.load_file (path ^ ".last-good") in
  Fs_compat.save_file path "unreadable primary";
  (match Agent.collect_pending config with
   | Error (Agent.Scan_skipped unavailable) ->
     check string "scan names the file it could not read" path unavailable.Goal_store.file
   | Ok _ -> fail "unavailable source was reported as a successful scan");
  check string "scan does not repair primary" "unreadable primary"
    (Fs_compat.load_file path);
  check string "scan preserves mirror" mirror
    (Fs_compat.load_file (path ^ ".last-good"))
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
    | Ok { Agent.collected; _ } -> collected
    | Error failure -> fail (Agent.scan_failure_to_string failure)
  in
  check bool "reconciliation does not call the model again" false
    (has_completion_work goal_id work);
  check string "proven verdict converges to completed" "awaiting_confirmation"
    (stored_phase config goal_id);
  match (ledger_record config goal_id).completion with
  | Goal_verification.Proof_proven verdict ->
    check string "the exact run survives reconciliation" "goal-run-before-crash"
      verdict.Goal_verification.verification_run_id
  | _ -> fail "reconciliation rewrote the proven ledger state"
;;

(* Mutate through the public Goal tool after the reviewer receives the frozen
   prompt, before its APPROVE comes back. This exercises the in-flight proof
   boundary without timing, threads, or a real evaluator. *)
let review_while_editing_goal config ctx goal_id edits =
  let prompts = ref [] in
  let calls = ref [] in
  let before_verdict prompt =
    prompts := !prompts @ [ prompt ];
    check bool "the reviewer received the original target" true
      (String_util.contains_substring prompt "<target_value>3</target_value>");
    List.iter
      (fun fields ->
        ignore
          (must_succeed "edit during proof review"
             (dispatch ctx ~name:"masc_goal_upsert"
                (("id", `String goal_id) :: fields))))
      edits
  in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:
      (recording_reviewer ~before_verdict calls
         [ "verifier-a", Stub_approve "three verified services reach target three" ])
    (fun () -> drain config);
  check int "one rendered prompt reached the reviewer" 1 (List.length !prompts);
  check (list string) "one review was issued" [ "verifier-a" ] !calls
;;

let check_obsolete_proof_not_applied config goal_id =
  check bool "obsolete approval cannot complete the goal" false
    (String.equal "awaiting_confirmation" (stored_phase config goal_id));
  match (ledger_record config goal_id).completion with
  | Goal_verification.Proof_proven _ ->
    fail "obsolete approval must not become durable proven evidence"
  | _ -> ()
;;

let test_target_edit_during_review_invalidates_approval () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Target changes during proof" in
  ignore (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  review_while_editing_goal config ctx goal_id
    [ [ "target_value", `String "300" ] ];
  (match Goal_store.find_goal config ~goal_id with
   | Goal_store.Goal_found goal -> check (option string) "the new target is retained"
       (Some "300") goal.Goal_store.target_value
   | Goal_store.Goal_absent -> fail "goal disappeared after editing its target"
   | Goal_store.Store_unavailable u -> fail (Goal_store.unavailable_to_string u));
  check_obsolete_proof_not_applied config goal_id
;;

let test_target_aba_during_review_invalidates_approval () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Target changes and returns during proof" in
  ignore (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  review_while_editing_goal config ctx goal_id
    [ [ "target_value", `String "300" ]; [ "target_value", `String "3" ] ];
  (match Goal_store.find_goal config ~goal_id with
   | Goal_store.Goal_found goal -> check (option string) "the target returned to its original text"
       (Some "3") goal.Goal_store.target_value
   | Goal_store.Goal_absent -> fail "goal disappeared after changing its target twice"
   | Goal_store.Store_unavailable u -> fail (Goal_store.unavailable_to_string u));
  check_obsolete_proof_not_applied config goal_id
;;

let test_priority_edit_during_review_preserves_approval () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Priority changes during proof" in
  ignore (must_succeed "set initial priority"
    (dispatch ctx ~name:"masc_goal_upsert"
       [ "id", `String goal_id; "priority", `Int 2 ]));
  ignore (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  review_while_editing_goal config ctx goal_id [ [ "priority", `Int 1 ] ];
  (match Goal_store.find_goal config ~goal_id with
   | Goal_store.Goal_found goal -> check int "priority edit is retained" 1 goal.Goal_store.priority
   | Goal_store.Goal_absent -> fail "goal disappeared after editing its priority"
   | Goal_store.Store_unavailable u -> fail (Goal_store.unavailable_to_string u));
  check string "priority does not change the reviewed success criterion"
    "awaiting_confirmation" (stored_phase config goal_id);
  match (ledger_record config goal_id).completion with
  | Goal_verification.Proof_proven _ -> ()
  | _ -> fail "an unchanged criterion must retain its proven verdict"
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
    | Ok { Agent.collected; _ } -> collected
    | Error failure -> fail (Agent.scan_failure_to_string failure)
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

(* One Verifying goal whose ledger cannot be re-armed must not stop the
   scan. The bad goal holds a human-confirmed proof for its current
   criterion while its phase is still Verifying: reconciliation finds no
   committed proof to replay, and re-arming refuses because the criterion is
   already proven. The other goal, an ordinary pending request, is still
   collected and still drained. *)
let test_one_unreconcilable_goal_does_not_stop_the_scan () =
  with_workspace
  @@ fun config ->
  let bad_goal_id =
    set_up_committed_proof_crash
      config
      ~outcome:Goal_verification.Proven
      ~evidence:"proven before the phase write"
  in
  let proven =
    match (ledger_record config bad_goal_id).completion with
    | Goal_verification.Proof_proven verdict -> verdict
    | _ -> fail "test setup: the bad goal needs a proven ledger row"
  in
  (match
     Goal_verification.record_human_confirmation
       config
       ~goal_id:bad_goal_id
       proven
       ~operator_id:"operator"
   with
   | Ok _ -> ()
   | Error msg -> fail msg);
  let ctx = workspace_ctx config in
  let good_goal_id = create_goal ctx "Goal beside an unreconcilable ledger" in
  ignore
    (must_succeed "request_complete" (transition ctx good_goal_id "request_complete"));
  (match Agent.collect_pending config with
   | Ok { Agent.collected; unreconciled } ->
     check bool "the healthy goal is still collected" true
       (has_completion_work good_goal_id collected);
     check bool "the unreconcilable goal is not collected" false
       (has_completion_work bad_goal_id collected);
     check (list string) "the scan names the one goal it could not reconcile"
       [ bad_goal_id ]
       (List.map (fun (failure : Agent.reconcile_failure) -> failure.failed_goal_id)
          unreconciled);
     check (list string) "it names the re-arm step as the one that failed"
       [ "rearm_proof" ]
       (List.map
          (fun (failure : Agent.reconcile_failure) ->
             Goal_verification_agent.reconcile_step_to_string failure.step)
          unreconciled)
   | Error failure -> fail (Agent.scan_failure_to_string failure));
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:
      (recording_reviewer (ref []) [ "verifier-a", Stub_approve "healthy goal verified" ])
    (fun () -> drain config);
  check string "the healthy goal is drained past the bad one" "awaiting_confirmation"
    (stored_phase config good_goal_id);
  check string "the bad goal stays verifying" "verifying" (stored_phase config bad_goal_id);
  (match (ledger_record config bad_goal_id).completion with
   | Goal_verification.Human_confirmed _ -> ()
   | _ -> fail "the scan rewrote the unreconcilable goal's ledger row");
  (* The drain above is the scan the operator's Goal row is derived from. *)
  let projection goal_id =
    match Goal_store.find_goal config ~goal_id with
    | Goal_store.Goal_found goal -> Goal_verification_agent.unreconciled_to_yojson goal
    | Goal_store.Goal_absent -> fail ("goal not found: " ^ goal_id)
    | Goal_store.Store_unavailable u -> fail (Goal_store.unavailable_to_string u)
  in
  (match projection bad_goal_id with
   | `Assoc fields ->
     check (option string) "the Goal row names the failed step" (Some "rearm_proof")
       (match List.assoc_opt "step" fields with Some (`String s) -> Some s | _ -> None);
     check bool "the Goal row carries the store's reason" true
       (match List.assoc_opt "detail" fields with
        | Some (`String detail) -> String.trim detail <> ""
        | _ -> false)
   | _ -> fail "the unreconcilable goal is missing from the Goal row projection");
  check bool "the drained goal carries no unreconciled reason" true
    (projection good_goal_id = `Null);
  ignore (must_succeed "drop" (transition ctx bad_goal_id "drop"));
  check bool "a goal the operator dropped no longer reads as stuck" true
    (projection bad_goal_id = `Null)
;;

(* The stuck list is derived from the latest scan, not accumulated. A goal
   the first scan could not re-arm (its criterion is already human-confirmed)
   gets a new criterion and is submitted again; the next scan finds it
   pending, the review defers, and the goal is still Verifying -- so only replacement, not the phase filter, can
   take it off the row. The server's planning row is checked on both sides. *)
let test_a_clean_scan_replaces_the_unreconciled_list () =
  with_workspace
  @@ fun config ->
  let goal_id =
    set_up_committed_proof_crash
      config
      ~outcome:Goal_verification.Proven
      ~evidence:"proven before the phase write"
  in
  let proven =
    match (ledger_record config goal_id).completion with
    | Goal_verification.Proof_proven verdict -> verdict
    | _ -> fail "test setup: the goal needs a proven ledger row"
  in
  (match
     Goal_verification.record_human_confirmation config ~goal_id proven
       ~operator_id:"operator"
   with
   | Ok _ -> ()
   | Error msg -> fail msg);
  let planning_row () =
    match Server_dashboard_http.dashboard_planning_http_json ~config with
    | `Assoc fields ->
      (match List.assoc_opt "goals" fields with
       | Some (`List goals) ->
         (match
            List.find_opt
              (function
                | `Assoc goal -> List.assoc_opt "id" goal = Some (`String goal_id)
                | _ -> false)
              goals
          with
          | Some (`Assoc goal) ->
            (match List.assoc_opt "verifier_unreconciled" goal with
             | Some value -> value
             | None -> fail "the planning row has no verifier_unreconciled key")
          | _ -> fail "the goal is missing from the planning rows")
       | _ -> fail "the planning snapshot has no goals list")
    | _ -> fail "the planning snapshot is not an object"
  in
  let deferring_drain () =
    with_lane_and_reviewer
      ~slots:(fun () -> Ok [ "verifier-a" ])
      ~reviewer:(recording_reviewer (ref []) [ "verifier-a", Stub_unavailable ])
      (fun () -> drain config)
  in
  deferring_drain ();
  (match planning_row () with
   | `Assoc fields ->
     check bool "the server row names the re-arm step" true
       (List.assoc_opt "step" fields = Some (`String "rearm_proof"))
   | _ -> fail "the stuck goal is not marked on the server's planning row");
  (match Goal_store.upsert_goal config ~id:goal_id ~target_value:"4" () with
   | Ok _ -> ()
   | Error e -> fail (Goal_store.write_error_to_string e));
  (* The edit takes the request back to Executing; submitting again puts the
     goal in Verifying under a criterion nobody has confirmed. *)
  ignore
    (must_succeed "request_complete"
       (transition (workspace_ctx config) goal_id "request_complete"));
  deferring_drain ();
  check string "the goal is still verifying" "verifying" (stored_phase config goal_id);
  check bool "the clean scan took it off the planning row" true (planning_row () = `Null)
;;

let test_superseded_review_keeps_the_evaluated_original_criterion () =
  let scenario request_new =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Historical verdict remains attached to its criterion" in
  ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
  let original_request, original_criterion = pending_identity config goal_id in
  let before_verdict prompt =
    check bool "review saw the original target" true
      (String_util.contains_substring prompt "<target_value>3</target_value>");
    ignore (must_succeed "edit" (dispatch ctx ~name:"masc_goal_upsert"
      [ "id", `String goal_id; "target_value", `String "300" ]));
    if request_new then
      ignore (must_succeed "request revised proof" (transition ctx goal_id "request_complete"))
  in
  with_lane_and_reviewer ~slots:(fun () -> Ok [ "verifier-a" ])
    ~reviewer:(recording_reviewer ~before_verdict (ref [])
      [ "verifier-a", Stub_approve "three verified services meet target three" ])
    (fun () -> drain config);
  let registry = Goal_verification_run_registry.global () in
  let runs = reviews_of_goal registry goal_id in
  (match runs with
   | [ { request_id; criterion; status = Goal_verification_run_registry.Completed
       { outcome;
         evaluated_verdict = Some (Goal_verification_run_registry.Approved { reason }); _ }; _ } ] ->
     (match request_new, outcome with
      | true, Goal_verification_run_registry.Superseded _
      | false, Goal_verification_run_registry.Deferred _ -> ()
      | _ -> fail "unexpected application settlement");
     check string "run belongs to the original request" original_request request_id;
     check bool "run holds the exact reviewed criterion" true
       (Goal_store.criterion_equal original_criterion criterion);
     check string "unapplied approval remains readable"
       "three verified services meet target three" reason
   | _ -> fail "superseded evaluation disappeared from its run history");
  if request_new then (
    let new_request, _ = pending_identity config goal_id in
    check bool "historical approval does not replace the new request" false
      (String.equal original_request new_request));
  check string "old proof cannot complete either case"
    (if request_new then "verifying" else "executing") (stored_phase config goal_id)
  in
  List.iter scenario [ false; true ]
;;

let test_wake_after_deferred_persist_survives_active_scan () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Wake retained across worker release" in
  ignore (must_succeed "initial request" (transition ctx goal_id "request_complete"));
  let old_request, _ = pending_identity config goal_id in
  let calls = ref [] in
  let injected = ref false in
  let scanned_while_active = ref false in
  let registry = Goal_verification_run_registry.global () in
  let finished, resolve_finished = Eio.Promise.create () in
  let resolved = ref false in
  let settle result =
    if not !resolved then (resolved := true; Eio.Promise.resolve resolve_finished result)
  in
  let saved_observer = Atomic.get Goal_verification_run_registry.change_observer_fn in
  let observer () =
    try
      let runs = reviews_of_goal registry goal_id in
      let has_outcome matches = List.exists
        (fun (run : Goal_verification_run_registry.run) -> match run.status with
         | Goal_verification_run_registry.Running -> false
         | Goal_verification_run_registry.Completed { outcome; _ } -> matches outcome)
        runs in
      if not !injected && has_outcome (function Goal_verification_run_registry.Deferred _ -> true | _ -> false) then (
        (* This notification runs after the old worker computed Deferred and
           persisted it, but before its in-flight claim is released. *)
        injected := true;
        ignore (must_succeed "edit after terminal observation"
          (dispatch ctx ~name:"masc_goal_upsert" ["id", `String goal_id; "target_value", `String "4"]));
        ignore (must_succeed "new request during old claim"
          (transition ctx goal_id "request_complete"));
        let new_request, _ = pending_identity config goal_id in
        check bool "new request has its own identity" false (String.equal old_request new_request);
        Atomic.set AR.run_llm_reviewer_fn
          (recording_reviewer calls ["verifier-a", Stub_approve "new target measured"]);
        check bool "scan ran against real active runtime" true (Agent.scan_active_once ());
        scanned_while_active := true;
        check int "active claim prevented second review during scan" 1 (List.length !calls))
      else if !injected && has_outcome (function Goal_verification_run_registry.Committed -> true | _ -> false) then
        settle (Ok ())
    with exn -> settle (Error (Printexc.to_string exn))
  in
  Fun.protect ~finally:(fun () -> Atomic.set Goal_verification_run_registry.change_observer_fn saved_observer)
    (fun () ->
      Atomic.set Goal_verification_run_registry.change_observer_fn observer;
      with_lane_and_reviewer ~slots:(fun () -> Ok ["verifier-a"])
        ~reviewer:(recording_reviewer calls ["verifier-a", Stub_unavailable])
        (fun () ->
          Eio.Switch.run (fun sw ->
            Goal_verification_agent.start ~sw ~config;
            match Eio.Promise.await finished with
            | Ok () -> () | Error message -> fail message)));
  check bool "wake was consumed while old claim active" true !scanned_while_active;
  check int "release delivered exactly one new review" 2 (List.length !calls);
  check string "new proof completed without another external wake" "awaiting_confirmation" (stored_phase config goal_id)
;;

(* A verifier lane that never answers must not keep its slot or the Goal's
   claim once the operator takes the Goal out of verifying. The first review
   hangs; Reopen cancels it and frees the claim, and the next request is
   reviewed and committed without any other wake. *)
(* Upper bound on the wait for the next review to commit. Every step is local
   and stubbed, so reaching it means the cancel never happened. *)
let hung_review_wait_s = 30.0

let test_reopen_from_verifying_cancels_a_hung_review () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Verifier never answers" in
  ignore (must_succeed "initial request" (transition ctx goal_id "request_complete"));
  let entered, resolve_entered = Eio.Promise.create () in
  let hanging_reviewer =
    fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ?goal_blocks:_ ~report_tool_schema:_
        ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
      ignore (Eio.Promise.try_resolve resolve_entered ());
      let never, _ = Eio.Promise.create () in
      Eio.Promise.await never
  in
  let calls = ref [] in
  let registry = Goal_verification_run_registry.global () in
  let finished, resolve_finished = Eio.Promise.create () in
  let saved_observer = Atomic.get Goal_verification_run_registry.change_observer_fn in
  let observer () =
    let committed =
      reviews_of_goal registry goal_id
      |> List.exists (fun (run : Goal_verification_run_registry.run) ->
        match run.status with
        | Goal_verification_run_registry.Completed
            { outcome = Goal_verification_run_registry.Committed; _ } -> true
        | Goal_verification_run_registry.Completed _
        | Goal_verification_run_registry.Running -> false)
    in
    if committed then ignore (Eio.Promise.try_resolve resolve_finished ())
  in
  Fun.protect ~finally:(fun () -> Atomic.set Goal_verification_run_registry.change_observer_fn saved_observer)
    (fun () ->
      Atomic.set Goal_verification_run_registry.change_observer_fn observer;
      with_lane_and_reviewer ~slots:(fun () -> Ok ["verifier-a"])
        ~reviewer:hanging_reviewer
        (fun () ->
          Eio.Switch.run (fun sw ->
            Goal_verification_agent.start ~sw ~config;
            Eio.Promise.await entered;
            Atomic.set AR.run_llm_reviewer_fn
              (recording_reviewer calls ["verifier-a", Stub_approve "measured after reopen"]);
            let reopened = must_succeed "reopen from verifying" (transition ctx goal_id "reopen") in
            check string "reopen leaves verifying" "executing" (json_state reopened [ "goal"; "phase" ]);
            ignore (must_succeed "new request" (transition ctx goal_id "request_complete"));
            let clock = match !workspace_clock with
              | Some clock -> clock
              | None -> fail "test setup: with_workspace did not record its clock" in
            match Eio.Time.with_timeout clock hung_review_wait_s (fun () ->
                Eio.Promise.await finished; Ok ()) with
            | Ok () -> ()
            | Error `Timeout ->
              fail (Printf.sprintf
                "no committed review %.0fs after reopen: the hung review was not \
                 cancelled or its claim was not released" hung_review_wait_s))));
  let runs = reviews_of_goal registry goal_id in
  check bool "the hung review was cancelled" true
    (List.exists (fun (run : Goal_verification_run_registry.run) ->
       match run.status with
       | Goal_verification_run_registry.Completed
           { outcome = Goal_verification_run_registry.Review_cancelled _; _ } -> true
       | Goal_verification_run_registry.Completed _
       | Goal_verification_run_registry.Running -> false) runs);
  check int "the new request was reviewed once" 1 (List.length !calls);
  check string "the new request committed" "awaiting_confirmation" (stored_phase config goal_id)
;;

let test_pending_before_phase_waits_for_explicit_request () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Pending persisted before phase" in
  let goal = match Goal_store.find_goal config ~goal_id with
    | Goal_store.Goal_found goal -> goal
    | Goal_store.Goal_absent -> fail "missing Goal"
    | Goal_store.Store_unavailable u -> fail (Goal_store.unavailable_to_string u) in
  (match Goal_verification.mark_proof_pending config ~goal_id
      ~criterion:(Goal_store.criterion_of_goal goal) with
   | Ok _ -> () | Error message -> fail message);
  let request_id, _ = pending_identity config goal_id in
  let calls = ref [] in
  with_lane_and_reviewer ~slots:(fun () -> Ok ["verifier-a"])
    ~reviewer:(recording_reviewer calls ["verifier-a", Stub_approve "measured"])
    (fun () -> drain config);
  check int "Executing pending never enters evaluator" 0 (List.length !calls);
  check string "phase did not change during scan" "executing" (stored_phase config goal_id);
  ignore (must_succeed "explicit retry" (transition ctx goal_id "request_complete"));
  let same_request, _ = pending_identity config goal_id in
  check string "retry converges the persisted request" request_id same_request;
  with_lane_and_reviewer ~slots:(fun () -> Ok ["verifier-a"])
    ~reviewer:(recording_reviewer calls ["verifier-a", Stub_approve "measured"])
    (fun () -> drain config);
  check int "converged request reviewed once" 1 (List.length !calls);
  check string "matching proof applied" "awaiting_confirmation" (stored_phase config goal_id)
;;

let test_new_request_rejects_old_answer_for_same_criterion () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Retry bound to one request" in
  ignore (must_succeed "first proof request" (transition ctx goal_id "request_complete"));
  let old_request, criterion = pending_identity config goal_id in
  let commit ~request_id ~verification_run_id decision evidence =
    Workspace_goals.commit_verifier_decision
      ~tool_name:"goal_verifier_commit" ~start_time:(Time_compat.now ())
      config ~goal_id ~request_id ~criterion ~verification_run_id ~decision ~evidence
  in
  ignore (must_succeed "first refusal"
    (commit ~request_id:old_request ~verification_run_id:"run-old"
       (Workspace_goals.Proof_refuted { reason = "not yet measured" }) "not yet measured"));
  ignore (must_succeed "second proof request" (transition ctx goal_id "request_complete"));
  let new_request, new_criterion = pending_identity config goal_id in
  check bool "same criterion is still current" true (Goal_store.criterion_equal criterion new_criterion);
  check bool "a new proof request has distinct identity" false (String.equal old_request new_request);
  let stale = commit ~request_id:old_request ~verification_run_id:"run-old-late"
      Workspace_goals.Proof_proven "late old answer" in
  check bool "old answer is rejected" false (Tool_result.is_success stale);
  let retained_request, _ = pending_identity config goal_id in
  check string "new pending was not consumed" new_request retained_request;
  check string "phase still awaits new proof" "verifying" (stored_phase config goal_id);
  ignore (must_succeed "new proof"
    (commit ~request_id:new_request ~verification_run_id:"run-new"
       Workspace_goals.Proof_proven "new measured evidence"));
  let record = ledger_record config goal_id in
  let verdict = match record.completion with
    | Goal_verification.Proof_proven verdict -> verdict
    | _ -> fail "new proof was not recorded" in
  let before = Yojson.Safe.to_string (Goal_verification.record_to_yojson record) in
  (match Goal_verification.record_proof_verdict config ~goal_id
      { verdict with recorded_at = "later observation" } with
   | Ok replay -> check string "exact replay retains original bytes" before
       (Yojson.Safe.to_string (Goal_verification.record_to_yojson replay))
   | Error message -> fail message);
  (match Goal_verification.record_proof_verdict config ~goal_id
      { verdict with verification_run_id = "another-run" } with
   | Error _ -> () | Ok _ -> fail "same outcome from another run replaced proof");
  (match Goal_verification.record_proof_verdict config ~goal_id
      { verdict with evidence = "different claim" } with
   | Error _ -> () | Ok _ -> fail "altered evidence replaced proof");
  check string "proof still names its accepted evidence" before
    (Yojson.Safe.to_string (Goal_verification.record_to_yojson (ledger_record config goal_id)))
;;

let test_pending_proof_binds_submitted_evidence () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Immutable submitted discussion" in
  let goal = match Goal_store.find_goal config ~goal_id with
    | Goal_store.Goal_found goal -> goal
    | Goal_store.Goal_absent -> fail "missing goal"
    | Goal_store.Store_unavailable u -> fail (Goal_store.unavailable_to_string u) in
  let criterion = Goal_store.criterion_of_goal goal in
  let item content = Workspace_verification_store.Evidence_collaboration {
    reference="board:submitted-source"; content;
    sha256=Digestif.SHA256.(to_hex (digest_string content)) } in
  let original = item {|{"post":{"content":"original secret source"}}|} in
  let mark ?submitted_evidence () =
    match Goal_verification.mark_proof_pending ?submitted_evidence config ~goal_id ~criterion with
    | Ok record -> record | Error detail -> fail detail in
  let first = mark ~submitted_evidence:[original] () in
  let pending record = match record.Goal_verification.completion with
    | Goal_verification.Proof_pending pending -> pending.request_id, record.Goal_verification.submitted_evidence
    | _ -> fail "not pending" in
  let first_id, _ = pending first in
  let replay_id, replay_items = pending (mark ()) in
  check string "ordinary retry preserves original request" first_id replay_id;
  check bool "ordinary retry preserves original source" true (replay_items = [original]);
  let loaded_id, loaded_items = pending (ledger_record config goal_id) in
  check string "disk reload preserves request" first_id loaded_id;
  check bool "disk reload preserves exact source" true (loaded_items = [original]);
  let public = Yojson.Safe.to_string (Goal_verification.record_to_yojson_for_goal ~goal first) in
  check bool "routine Goal projection omits source body" false
    (String_util.contains_substring public "original secret source");
  let changed = item {|{"post":{"content":"replacement source"}}|} in
  let changed_id, changed_items = pending (mark ~submitted_evidence:[changed] ()) in
  check bool "changed submitted source creates a new request" false (changed_id = first_id);
  check bool "new request names new source" true (changed_items = [changed]);
  let same_id, _ = pending (mark ~submitted_evidence:[changed] ()) in
  check string "same criterion and exact source are idempotent" changed_id same_id;
  ignore (must_succeed "start submitted proof" (transition ctx goal_id "request_complete"));
  let verdict : Goal_verification.verdict = {
    outcome=Goal_verification.Refuted {reason="needs more work"}; request_id=changed_id; criterion;
    verification_run_id="submitted-source-review";
    authority=Masc_domain.System_llm_agent {agent_run_id="verifier_exact"};
    evidence="reviewed original snapshot"; recorded_at=Masc_domain.now_iso () } in
  (match Goal_verification.record_proof_verdict config ~goal_id verdict with
   | Ok record -> check bool "committed verdict retains submitted bytes" true
       (record.submitted_evidence = [changed])
   | Error detail -> fail detail);
  let replacement = dispatch ctx ~name:"masc_goal_transition"
    ["goal_id", `String goal_id; "action", `String "request_complete"; "evidence_refs", `List []] in
  check bool "committed proof does not silently accept replacement refs" false (Tool_result.is_success replacement);
  ignore (must_succeed "reconcile prior result" (transition ctx goal_id "request_complete"));
  let retry_id, retry_items = pending (mark ()) in
  check bool "refuted retry receives new identity" false (retry_id = changed_id);
  check bool "omitted refuted retry retains submitted bytes" true (retry_items = [changed]);
  let _, cleared = pending (mark ~submitted_evidence:[] ()) in
  check bool "explicit empty submission clears previous evidence" true (cleared = []);
  ignore (must_succeed "start cleared proof" (transition ctx goal_id "request_complete"));
  let request_id, _ = pending_identity config goal_id in
  (match Goal_verification.record_proof_verdict config ~goal_id
      {verdict with outcome=Goal_verification.Proven; request_id; verification_run_id="cleared-source-review"} with
   | Ok _ -> () | Error detail -> fail detail);
  ignore (must_succeed "reconcile completed proof" (transition ctx goal_id "request_complete"));
  let late = dispatch ctx ~name:"masc_goal_transition"
    ["goal_id", `String goal_id; "action", `String "request_complete"; "evidence_refs", `List []] in
  check bool "confirmation phase does not silently accept evidence refs" false (Tool_result.is_success late)
;;

let test_invalid_goal_evidence_does_not_request_proof () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Evidence capture failure" in
  List.iter (fun evidence_refs ->
    let result = dispatch ctx ~name:"masc_goal_transition"
      ["goal_id", `String goal_id; "action", `String "request_complete"; "evidence_refs", evidence_refs] in
    check bool "invalid evidence request fails" false (Tool_result.is_success result);
    check string "failed capture does not move Goal into verification" "executing" (stored_phase config goal_id))
    [`Null; `String "board:missing"; `List [`Int 1]; `List [`String "not-a-reference"];
     `List [`String "fusion:missing-goal-submission-source"]]
;;

let () =
  configure_prompt_registry ();
  run
    "goal_verification_agent"
    [ ( "submitted evidence"
      , [ test_case "pending proof binds exact submitted source" `Quick test_pending_proof_binds_submitted_evidence
        ; test_case "invalid evidence leaves goal unchanged" `Quick test_invalid_goal_evidence_does_not_request_proof ] )
    ; ( "historical review evidence"
      , [ test_case "superseded review keeps evaluated original criterion" `Quick
            test_superseded_review_keeps_the_evaluated_original_criterion ] )
    ; ( "drain"
      , [ test_case "wake after deferred persistence survives active scan" `Quick
            test_wake_after_deferred_persist_survives_active_scan
        ; test_case "pending before phase waits for explicit retry" `Quick
            test_pending_before_phase_waits_for_explicit_request
        ; test_case "reopen from verifying cancels a hung review" `Quick
            test_reopen_from_verifying_cancels_a_hung_review
        ; test_case "new request rejects an old answer for identical criteria" `Quick
            test_new_request_rejects_old_answer_for_same_criterion
        ; test_case "proof pending drains to completed" `Quick
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
      , [ test_case "scan preserves source failure" `Quick test_scan_preserves_source_failure
        ; test_case "skipped scan records one row and one WARN per cycle" `Quick
            test_skipped_scan_records_one_row_and_one_warn_per_cycle
        ; test_case "healthy store scan records no skipped row" `Quick
            test_healthy_store_scan_records_no_skipped_row
        ; test_case "lane unavailable keeps the pending row" `Quick
            test_lane_unavailable_keeps_the_pending_row
        ; test_case "malformed reply fails over to the next slot" `Quick
            test_malformed_reply_fails_over_to_the_next_slot
        ; test_case "all slots failed keeps the pending row" `Quick
            test_all_slots_failed_keeps_the_pending_row
        ; test_case "approve without a stated reason does not commit" `Quick
            test_approve_without_a_stated_reason_does_not_commit
        ] )
    ; ( "in-flight criterion edits"
      , [ test_case "target edit invalidates the in-flight approval" `Quick
            test_target_edit_during_review_invalidates_approval
        ; test_case "target ABA invalidates the in-flight approval" `Quick
            test_target_aba_during_review_invalidates_approval
        ; test_case "priority edit preserves the in-flight approval" `Quick
            test_priority_edit_during_review_preserves_approval
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
        ; test_case
            "one unreconcilable goal does not stop the scan"
            `Quick
            test_one_unreconcilable_goal_does_not_stop_the_scan
        ; test_case
            "a clean scan replaces the unreconciled list"
            `Quick
            test_a_clean_scan_replaces_the_unreconciled_list
        ; test_case "verifying goal with a missing request is rearmed and drained"
            `Quick
            test_verifying_goal_with_a_missing_request_is_rearmed_and_drained
        ] )
    ]
;;
