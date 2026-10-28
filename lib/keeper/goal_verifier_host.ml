module W = Goal_verifier_worker
module V = Goal_verifier_original
module R = Goal_verification_run_registry
module P = Lane_addon_request_progress
module AR = Task.Anti_rationalization
module Observer = Lane_addon_request_receipt
open Result.Syntax
type error = Unavailable of string | Invalid_original of string | Conflict of string
let error_to_string = function Unavailable d | Invalid_original d | Conflict d -> d
let worker_error = function
  | W.Store_unavailable d | Execution_pending d -> Unavailable d
  | Original_invalid d -> Invalid_original d
  | Authority_changed d -> Conflict d
let worker result = Result.map_error worker_error result
let invalid result = Result.map_error (fun d -> Invalid_original d) result
let authority_actor = Standalone_lane.to_id Standalone_lane.Verifier
let installation_id = W.host_installation_id
let package_id = W.host_package_id

let read_registry ~registry retained =
  let* () = if W.destination retained = (installation_id, package_id) then Ok ()
    else Error (Conflict "Goal original belongs to another host destination") in
  let run = W.run_identity retained in
  let subject = V.subject (W.original retained) in
  match R.get registry ~run_id:run.run_id with
  | None -> Ok None
  | Some (R.Review row) when row.goal_id = subject.goal_id && row.request_id = subject.request_id
      && Goal_store.criterion_equal row.criterion subject.criterion
      && row.started_at = run.started_at && row.authority_actor = authority_actor -> Ok (Some row)
  | Some (R.Review _ | R.Scan_skipped _) -> Error (Conflict "Goal registry run belongs to another original")

let ensure_registered ~registry retained =
  let* present = read_registry ~registry retained in
  let* () = match present with
    | Some _ -> Ok ()
    | None ->
      let run = W.run_identity retained in
      let subject = V.subject (W.original retained) in
      (try
         R.register_running registry ~run_id:run.run_id ~goal_id:subject.goal_id
           ~request_id:subject.request_id ~criterion:subject.criterion ~review_kind:R.Proof
           ~authority_actor ~started_at:run.started_at;
         Ok ()
       with Sys_error detail -> Error (Unavailable detail)) in
  let* observed = read_registry ~registry retained in
  match observed with Some _ -> Ok () | None -> Error (Unavailable "Goal run registration not observed")

type completion = {
  evaluated : R.evaluated_verdict option;
  runtime : string option;
  tools : Verification_run_registry.tool_observation list;
  elapsed : float;
}
let completion ~registry retained =
  let* receipt = worker (W.observed_receipt retained) in
  let* tools = worker (W.tool_observations retained) in
  match receipt with
  | Some receipt ->
    let result = W.goal_admission_result receipt.result in
    let evaluated = Option.map (function
      | AR.Approve reason -> R.Approved {reason}
      | Reject reason -> R.Rejected {reason}) result.verdict in
    Ok {evaluated; runtime=Some result.evaluator_runtime; tools; elapsed=receipt.elapsed_s}
  | None ->
    let* prior = read_registry ~registry retained in
    let elapsed = match prior with
      | Some {R.status=R.Completed {elapsed_s; _}; _} -> elapsed_s
      | None | Some {R.status=R.Running; _} -> max 0. (Time_compat.now () -. (W.run_identity retained).started_at) in
    Ok {evaluated=None; runtime=None; tools; elapsed}

let same_facts expected ~evaluated_verdict ~evaluator_runtime ~tools ~elapsed_s =
  expected.evaluated = evaluated_verdict && expected.runtime = evaluator_runtime
  && expected.tools = tools && expected.elapsed = elapsed_s

let run_row retained status : R.run =
  let run = W.run_identity retained in
  let subject = V.subject (W.original retained) in
  {run_id=run.run_id; goal_id=subject.goal_id; request_id=subject.request_id;
   criterion=subject.criterion; review_kind=R.Proof; authority_actor;
   started_at=run.started_at; status}

let completion_payload retained expected outcome =
  R.run_to_yojson (run_row retained (R.Completed {outcome;
    evaluated_verdict=expected.evaluated; evaluator_runtime=expected.runtime;
    tools=expected.tools; elapsed_s=expected.elapsed}))

let observer_intent ~store retained stage payload =
  let* payload = invalid (Lane_addon_action.canonical payload) in
  let observer = P.observer (W.progress retained) in
  let publication = match stage with Observer.Registration -> observer.registration
    | Completion -> observer.completion in
  match publication with
  | Observer.Pending receipt | Acknowledged receipt ->
    if Yojson.Safe.equal receipt.payload payload then Ok (retained,receipt)
    else Error (Conflict "Goal observer intent differs from its exact original publication")
  | Unobserved ->
    let* receipt = invalid (Observer.make ~observed_at:(Time_compat.now ()) ~payload) in
    let* retained = worker (W.record_observer ~store ~retained (Observer.Intended (stage,receipt))) in
    Ok (retained,receipt)

let observer_ack ~store retained stage (receipt : Observer.receipt) =
  let observer = P.observer (W.progress retained) in
  let publication = match stage with Observer.Registration -> observer.registration
    | Completion -> observer.completion in
  match publication with
  | Observer.Acknowledged observed when observed.digest=receipt.digest -> Ok retained
  | Pending observed when observed.digest=receipt.digest ->
    worker (W.record_observer ~store ~retained (Observer.Recorded (stage,receipt.digest)))
  | Unobserved | Pending _ | Acknowledged _ ->
    Error (Conflict "Goal observer acknowledgement differs from its original intent")

let publish ~store ~registry retained ~outcome =
  let* () = ensure_registered ~registry retained in
  let* expected = completion ~registry retained in
  let* () = match outcome, expected.evaluated with
    | (R.Reviewed | Committed), None -> Error (Invalid_original "Goal proof observation lacks a retained verdict")
    | (Reviewed | Committed), Some _ | (Superseded _ | Deferred _ | Raised _ | Review_cancelled _), _ -> Ok () in
  let confirmed row = match row.R.status with
    | R.Running -> false
    | Completed {outcome=observed; evaluated_verdict; evaluator_runtime; tools; elapsed_s} ->
      same_facts expected ~evaluated_verdict ~evaluator_runtime ~tools ~elapsed_s
      && (observed = outcome || observed = R.Committed) in
  let* prior = read_registry ~registry retained in
  let* publication = match P.phase (W.progress retained),outcome with
    | P.Finished _,R.Committed ->
      let* retained,registration = observer_intent ~store retained Observer.Registration
        (R.run_to_yojson (run_row retained R.Running)) in
      let* retained,completion = observer_intent ~store retained Observer.Completion
        (completion_payload retained expected outcome) in
      Ok (Some (retained,registration,completion))
    | (Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
      | Commit_unknown _ | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _),
      (Reviewed | Committed | Superseded _ | Deferred _ | Raised _ | Review_cancelled _) -> Ok None in
  let record_completion () =
    try match R.mark_completed_confirmed registry ~run_id:(W.run_identity retained).run_id ~outcome
      ~evaluated_verdict:expected.evaluated ~tools:expected.tools ?evaluator_runtime:expected.runtime
      ~elapsed_s:expected.elapsed () with
    | `Completed -> Ok true
    | `Unknown -> Error (Unavailable "Goal run vanished before completion publication")
    with Sys_error detail -> Error (Unavailable detail) in
  let* recorded = match prior with
    | Some row when confirmed row ->
      (match publication with Some _ -> record_completion () | None -> Ok false)
    | Some {R.status=R.Completed {evaluated_verdict; evaluator_runtime; tools; elapsed_s; _}; _} ->
      if Option.is_some evaluated_verdict
          && not (same_facts expected ~evaluated_verdict ~evaluator_runtime ~tools ~elapsed_s)
      then Error (Conflict "Goal registry already retains a different structured judgment or its observations")
      else record_completion ()
    | None | Some {R.status=R.Running; _} -> record_completion () in
  let* () = if recorded then Ok () else
    let* observed = read_registry ~registry retained in
    match observed with
    | Some row when confirmed row -> Ok ()
    | None | Some _ -> Error (Unavailable "Goal completion receipt not observed for its exact original") in
  match publication with
  | None -> Ok ()
  | Some (retained,registration,completion) ->
    let* retained = observer_ack ~store retained Observer.Registration registration in
    let* _ = observer_ack ~store retained Observer.Completion completion in Ok ()

let needs_recovery ~registry retained =
  let terminal ~conflicted =
    let* expected = completion ~registry retained in
    let* row = read_registry ~registry retained in
    match row with
    | None | Some {R.status=R.Running; _} -> Ok true
    | Some {R.status=R.Completed {outcome; evaluated_verdict; evaluator_runtime; tools; elapsed_s}; _} ->
      if not (same_facts expected ~evaluated_verdict ~evaluator_runtime ~tools ~elapsed_s)
      then Ok true
      else Ok (match outcome with
        | R.Committed -> false
        | Superseded _ -> not conflicted
        | Reviewed | Deferred _ | Raised _ | Review_cancelled _ -> true) in
  match P.phase (W.progress retained) with
  | P.Judged _ | Committing _ | Commit_unknown _ -> Ok true
  | Captured -> Ok false
  | Admission_wait _ | Dispatch_pending _ | Rejected _ | Subdividing _ | Subdivided _ ->
    let* expected = completion ~registry retained in
    let* row = read_registry ~registry retained in
    (match row with
     | Some {R.status=R.Completed {evaluated_verdict; evaluator_runtime; tools; elapsed_s; _}; _} ->
       Ok (not (same_facts expected ~evaluated_verdict ~evaluator_runtime ~tools ~elapsed_s))
     | None | Some {R.status=R.Running; _} -> Ok true)
  | Finished _ ->
    (match (P.observer (W.progress retained)).completion with
     | Observer.Acknowledged receipt ->
       let* expected = completion ~registry retained in
       let* payload = invalid (Lane_addon_action.canonical (completion_payload retained expected R.Committed)) in
       if Yojson.Safe.equal receipt.payload payload then Ok false
       else Error (Conflict "Goal final publication acknowledgement differs from its original proof")
     | Unobserved | Pending _ -> terminal ~conflicted:false)
  | Conflicted _ -> terminal ~conflicted:true

let evidence_json items = `List (List.map Workspace_verification_store.submitted_evidence_item_to_yojson items)
let bound_pending original (record : Goal_verification.record) =
  let subject = V.subject original in
  record.goal_id = subject.goal_id
  && Yojson.Safe.equal (evidence_json record.submitted_evidence) (evidence_json (V.submitted_evidence original))
  && match record.completion with
     | Goal_verification.Proof_pending pending -> pending.request_id = subject.request_id
       && Goal_store.criterion_equal pending.criterion subject.criterion
     | Completion_idle | Proof_proven _ | Proof_refuted _ | Human_confirmed _ -> false

let original_verdict retained =
  let* receipt = worker (W.restored_receipt retained) in
  match receipt with
  | Some receipt ->
    (match receipt.result.verdict with
     | Some (AR.Approve evidence) when String.trim evidence <> "" ->
       Ok (Goal_verification.Proven, Workspace_goals.Proof_proven, evidence)
     | Some (Reject reason) when String.trim reason <> "" ->
       Ok (Goal_verification.Refuted {reason}, Workspace_goals.Proof_refuted {reason}, reason)
     | None | Some (Approve _ | Reject _) -> Error (Invalid_original "Goal judgment has no stated reason"))
  | None -> Error (Invalid_original "Goal host has no retained structured judgment")

let before_json record = `Assoc ["schema", `String "goal_verifier_before/v1";
  "record", (match record with None -> `Null | Some record -> Goal_verification.record_to_yojson record)]
let before_record json =
  match json with
  | `Assoc fields ->
    let* () = Json_util.reject_unknown_fields ~surface:"goal_verifier_before"
      ~allowed:["schema"; "record"] fields in
    (match List.assoc_opt "schema" fields, List.assoc_opt "record" fields with
     | Some (`String "goal_verifier_before/v1"), Some `Null -> Ok None
     | Some (`String "goal_verifier_before/v1"), Some encoded ->
       Result.map Option.some (Goal_verification.record_of_yojson encoded)
     | _ -> Error "invalid Goal before-state")
  | _ -> Error "Goal before-state must be an object"

let commit_proof ~config ~store ~registry retained =
  let original = W.original retained in
  let* () = if String.equal config.Workspace.base_path (V.base_path original) then Ok ()
    else Error (Conflict "Goal judgment belongs to another captured workspace") in
  let subject = V.subject original in
  let run = W.run_identity retained in
  let* outcome, decision, evidence = original_verdict retained in
  let* receipt = worker (W.retained_judgment retained) in
  let* digest = invalid (V.digest original) in
  let after = `Assoc ["schema", `String "goal_verifier_host_commit/v1";
    "original_digest", `String digest; "receipt", receipt;
    "goal_id", `String subject.goal_id; "request_id", `String subject.request_id;
    "criterion", Goal_store.criterion_to_yojson subject.criterion;
    "verification_run_id", `String run.run_id; "authority_actor", `String authority_actor;
    "evidence", `String evidence] in
  let* () = publish ~store ~registry retained ~outcome:R.Reviewed in
  let read_goal callback =
    Goal_store.transact_goal config ~goal_id:subject.goal_id (fun goal ->
      let* record = Goal_verification.get_record_authoritative config ~goal_id:subject.goal_id in
      let* value = callback goal record in Ok (goal, value))
    |> Result.map snd |> Result.map_error Goal_store.write_error_to_string in
  let* change = match P.phase (W.progress retained) with
    | Committing commit | Commit_unknown (commit,_) | Finished commit | Conflicted (commit,_) -> Ok commit.change
    | Judged _ ->
      let* before = Result.map_error (fun d -> Unavailable d)
        (read_goal (fun _ record -> Ok (before_json record))) in
      Ok {P.before; after}
    | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _ | Subdividing _ | Subdivided _ ->
      Error (Invalid_original "Goal commit has no original judgment frontier") in
  let authenticate (change : P.change) =
    let* record = before_record change.before in
    if not (Yojson.Safe.equal change.after after)
       || (match record with None -> false | Some record -> record.Goal_verification.goal_id <> subject.goal_id)
    then Error "Goal host intent differs from its exact original domain payload" else Ok record in
  let matches (record : Goal_verification.record) (verdict : Goal_verification.verdict) =
    record.goal_id = subject.goal_id
    && Yojson.Safe.equal (evidence_json record.submitted_evidence) (evidence_json (V.submitted_evidence original))
    && verdict.outcome = outcome && verdict.request_id = subject.request_id
    && Goal_store.criterion_equal verdict.criterion subject.criterion
    && verdict.verification_run_id = run.run_id && verdict.authority = Workspace_goals.verifier_authority
    && verdict.evidence = evidence in
  let proof_phase = function
    | Goal_phase.Verifying -> `Partial
    | Paused Resume_verifying | Blocked Resume_verifying -> `Settled
    | Awaiting_confirmation | Completed
    | Paused Resume_awaiting_confirmation | Blocked Resume_awaiting_confirmation ->
      (match outcome with Goal_verification.Proven -> `Settled | Refuted _ -> `Different)
    | Executing | Paused Resume_executing | Blocked Resume_executing ->
      (match outcome with Goal_verification.Refuted _ -> `Settled | Proven -> `Different)
    | Dropped -> `Different in
  let observe_once change =
    let* before = authenticate change in
    read_goal (fun goal record ->
      let current_criterion = Goal_store.criterion_of_goal goal in
      let criterion_matches = Goal_store.criterion_equal current_criterion subject.criterion in
      let exact_proof = match record with
        | Some ({Goal_verification.completion=(Proof_proven verdict | Proof_refuted verdict
          | Human_confirmed (verdict,_)); _} as record) -> criterion_matches && matches record verdict
        | None | Some {completion=(Completion_idle | Proof_pending _); _} -> false in
      if exact_proof then
        match proof_phase goal.phase with
        | `Partial -> Ok (`Partial)
        | `Settled -> Ok (`Observed change.after)
        | `Different ->
          Ok (`Observed (`Assoc ["phase",Goal_phase.to_yojson goal.phase; "proof",before_json record]))
      else
        let admitted = match goal.phase with
          | Goal_phase.Verifying | Paused Resume_verifying | Blocked Resume_verifying -> true
          | Executing | Awaiting_confirmation | Completed | Dropped
          | Paused (Resume_executing | Resume_awaiting_confirmation)
          | Blocked (Resume_executing | Resume_awaiting_confirmation) -> false in
        if admitted && criterion_matches && Yojson.Safe.equal (before_json record) (before_json before)
            && (match record with Some record -> bound_pending original record | None -> false)
        then Ok (`Observed change.before)
        else Ok (`Observed (`Assoc ["phase",Goal_phase.to_yojson goal.phase;
          "criterion",Goal_store.criterion_to_yojson current_criterion; "proof",before_json record]))) in
  let observe change =
    let* observed = observe_once change in
    match observed with
    | `Observed json -> Ok json
    | `Partial ->
      let* _ = Workspace_goals.reconcile_committed_proof config ~goal_id:subject.goal_id
        |> Result.map_error Goal_store.write_error_to_string in
      let* settled = observe_once change in
      (match settled with `Observed json -> Ok json | `Partial -> Error "exact Goal proof phase remains unreconciled") in
  let apply change =
    let* before = authenticate change in
    let* () = match before with
      | Some record when bound_pending original record -> Ok ()
      | None | Some _ -> Error "Goal before-state is not the original pending proof" in
    let result = Workspace_goals.commit_verifier_decision
      ~before_proof_commit:(Candle_snapshot.before_proof_commit config)
      ~tool_name:"goal_verifier_commit" ~start_time:(Tool_timing.start ()) config
      ~goal_id:subject.goal_id ~request_id:subject.request_id ~criterion:subject.criterion
      ~verification_run_id:run.run_id ~decision ~evidence in
    if Tool_result.is_success result then Ok () else Error (Tool_result.message result) in
  let* () = match W.commit ~store ~retained ~change ~observe ~apply with
    | Ok () -> Ok ()
    | Error error ->
      (match W.load ~store ~installation_id ~package_id
          ~goal_id:subject.goal_id ~request_id:subject.request_id ~attempt:(V.attempt original) with
       | Ok (Some current) ->
         (match P.phase (W.progress current) with
          | Conflicted _ -> Error (Conflict (error_to_string (worker_error error)))
          | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
          | Finished _ | Rejected _ | Subdividing _ | Subdivided _ -> Error (worker_error error))
       | Ok None | Error _ -> Error (worker_error error)) in
  let* current = worker (W.load ~store ~installation_id ~package_id
    ~goal_id:subject.goal_id ~request_id:subject.request_id ~attempt:(V.attempt original)) in
  match current with
  | Some retained -> publish ~store ~registry retained ~outcome:R.Committed
  | None -> Error (Unavailable "Goal original vanished after proof commitment")
