module O = Verifier_review_owner
module V = Verifier_review_original
module P = Lane_addon_request_progress
module Receipt = Lane_addon_request_receipt
module R = Verification_run_registry
module AR = Task.Anti_rationalization
open Result.Syntax

let authority = Masc_domain.System_llm_agent {
  agent_run_id=Standalone_lane.to_id Standalone_lane.Verifier}

let terminal_authority_of_conflict ~task_id observed =
  let* task = match observed with
    | `Assoc [("conflicting_task", json)] -> Masc_domain.task_of_yojson json
    | _ -> Error "retained commit conflict does not contain one authoritative Task" in
  let* () = if task.Masc_domain.id=task_id then Ok ()
    else Error "retained commit conflict belongs to another Task" in
  let* status = Task_status_observation.of_yojson
    (Task_status_observation.to_yojson task.task_status) in
  match status with
  | Masc_domain.Done {assignee; _} -> Ok (Printf.sprintf "Done (producer=%s)" assignee)
  | Cancelled {cancelled_by; _} -> Ok (Printf.sprintf "Cancelled by %s" cancelled_by)
  | Todo | Claimed _ | InProgress _ | AwaitingVerification _ ->
    Error "retained commit conflicts with a nonterminal Task"

let owner_error = function
  | O.Not_found -> "retained review original is absent"
  | Load_store_unavailable detail | Corrupt_original detail -> detail

let save ~store retained event =
  O.advance ~store retained (P.Observer event) |> Result.map_error owner_error

let judgment retained =
  match P.phase (O.progress retained) with
  | P.Judged judgment -> Ok judgment
  | Committing commit | Commit_unknown (commit,_) | Finished commit
  | Conflicted (commit,_) -> Ok commit.judgment
  | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _
  | Subdividing _ | Subdivided _ -> Error "review publication lacks a retained judgment"

let evaluated_outcome result = match result.AR.verdict with
  | Some (Approve reason) -> Ok (R.Approved {reason})
  | Some (Reject reason) -> Ok (R.Rejected {reason})
  | None -> Error "review publication lacks a structured verdict"

let validate_execution_fields ~original ~result (row:R.run) =
  let request=V.review_request original in
  let* evaluated=evaluated_outcome result in
  let* () = if row.verification_id=V.verification_id original
      && row.task_id=request.AR.task_id && row.producer=request.agent_name
      && row.authority_actor=Masc_domain.completion_authority_actor authority
      && row.authority_kind=Masc_domain.completion_authority_kind authority
    then Ok () else Error "review observer registration differs from its original" in
  match row.status with
  | R.Completed {outcome; evaluator_runtime; _}
      when outcome=evaluated && evaluator_runtime=Some result.evaluator_runtime -> Ok ()
  | Running | Completed _ -> Error "review observer execution differs from its retained judgment"

let validate_execution retained row =
  let original=O.original retained in
  let* json=judgment retained in
  let* result,_=O.judgment_of_json ~original json in
  validate_execution_fields ~original ~result row

let canonical_row row = Lane_addon_action.canonical (R.run_to_yojson row)

let intent ~store retained stage payload =
  let* payload=Lane_addon_action.canonical payload in
  let observer=P.observer (O.progress retained) in
  let publication=match stage with Receipt.Registration -> observer.registration
    | Completion -> observer.completion in
  match publication with
  | Receipt.Pending receipt | Acknowledged receipt ->
    if Yojson.Safe.equal receipt.payload payload then Ok (retained,receipt)
    else Error "review observer intent differs from its immutable original"
  | Unobserved ->
    let* receipt=Receipt.make ~observed_at:(Time_compat.now ()) ~payload in
    let* retained=save ~store retained (Receipt.Intended (stage,receipt)) in
    Ok (retained,receipt)

let execution_receipt ~original ~result ~before ~expected =
  let* expected=R.completed_run_of_yojson (R.run_to_yojson expected) in
  let* ()=validate_execution_fields ~original ~result expected in
  let* execution=canonical_row expected in
  let* before=Verifier_review_commit_intent.before_of_status ~original before in
  Receipt.make ~observed_at:(Time_compat.now ())
    ~payload:(`Assoc ["before",before;"execution",execution])

let captured_execution retained =
  let* receipt=match (P.observer (O.progress retained)).registration with
    | Receipt.Pending receipt | Acknowledged receipt -> Ok receipt
    | Unobserved -> Error "original execution observations were not retained; recovery cannot reconstruct tools or elapsed time" in
  let* fields=Run_registry_core.Json.object_fields receipt.payload in
  let* ()=Run_registry_core.Json.exact_fields ~required:["before";"execution"] fields in
  let* before=match List.assoc_opt "before" fields with
    | Some json -> Ok json | None -> Error "review observer has no original before-state" in
  let* _=Verifier_review_commit_intent.before_status ~original:(O.original retained) before in
  let* execution=match List.assoc_opt "execution" fields with
    | Some json -> R.completed_run_of_yojson json
    | None -> Error "review observer has no execution row" in
  let* ()=validate_execution retained execution in Ok (before,execution)

let captured_before retained =
  let* before,_=captured_execution retained in
  Verifier_review_commit_intent.before_status ~original:(O.original retained) before

let terminal_expected retained =
  let* before,execution=captured_execution retained in
  let* commit,outcome = match P.phase (O.progress retained),execution.status with
    | P.Finished commit,R.Completed {outcome;_} -> Ok (commit,outcome)
    | Conflicted (commit,observed),R.Completed _ ->
      let outcome=match terminal_authority_of_conflict ~task_id:execution.task_id observed with
        | Ok authority -> R.Superseded_by {authority}
        | Error detail -> R.Commit_failed {detail} in
      Ok (commit,outcome)
    | (Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
      | Commit_unknown _ | Finished _ | Conflicted _ | Rejected _ | Subdividing _
      | Subdivided _),(R.Running | R.Completed _) -> Error "review has no terminal retained commit fact" in
  let* _=Verifier_review_commit_intent.decode ~original:(O.original retained)
    ~judgment:commit.P.judgment ~authority commit.change in
  let* ()=if Yojson.Safe.equal before commit.change.before then Ok ()
    else Error "terminal commit before-state differs from its captured original observation" in
  match execution.status with
  | R.Completed {evaluator_runtime; elapsed_s; tools; _} ->
    Ok {execution with status=R.Completed {outcome;evaluator_runtime;elapsed_s;tools}}
  | Running -> Error "review execution observation is not completed"

let needs_publication retained =
  match (P.observer (O.progress retained)).completion with
  | Receipt.Unobserved | Pending _ -> Ok true
  | Acknowledged receipt ->
    let* expected=terminal_expected retained in
    let* payload=canonical_row expected in
    if Yojson.Safe.equal receipt.payload payload then Ok false
    else Error "review Completion ACK differs from its original terminal fact"

let ack ~store retained stage (receipt:Receipt.receipt) =
  let observer=P.observer (O.progress retained) in
  let publication=match stage with Receipt.Registration -> observer.registration
    | Completion -> observer.completion in
  match publication with
  | Receipt.Acknowledged observed when observed.digest=receipt.digest -> Ok retained
  | Pending observed when observed.digest=receipt.digest ->
    save ~store retained (Receipt.Recorded (stage,receipt.digest))
  | Unobserved | Pending _ | Acknowledged _ ->
    Error "review publication ACK does not match its retained intent"

let publish_terminal ~store ~registry ~retained ~outcome =
  let* expected=terminal_expected retained in
  let* ()=match expected.R.status with
    | Completed terminal when terminal.outcome=outcome -> Ok ()
    | Running | Completed _ -> Error "review publication outcome differs from its terminal owner fact" in
  let* pending=needs_publication retained in
  if not pending then Ok () else
  let* payload=canonical_row expected in
  let* retained,completion=intent ~store retained Receipt.Completion payload in
  let* ()=R.publish_terminal_confirmed registry ~expected
    |> Result.map_error R.publication_error_to_string in
  let registration=(P.observer (O.progress retained)).registration in
  let* registration=match registration with
    | Receipt.Pending receipt | Acknowledged receipt -> Ok receipt
    | Unobserved -> Error "review registration intent vanished before ACK" in
  let* retained=ack ~store retained Receipt.Registration registration in
  let* _=ack ~store retained Receipt.Completion completion in Ok ()

let recover_terminal ~store ~registry ~retained =
  let* expected=terminal_expected retained in
  match expected.R.status with
  | R.Completed {outcome;_} ->
    let* ()=publish_terminal ~store ~registry ~retained ~outcome in Ok outcome
  | Running -> Error "retained terminal publication has no completion"
