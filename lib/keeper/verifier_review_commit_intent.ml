(** Pure authentication of the one retained Task commit intent. *)
module O = Verifier_review_owner
module V = Verifier_review_original
module P = Lane_addon_request_progress
module AR = Task.Anti_rationalization
open Result.Syntax

let before_status ~original before =
  let request=V.review_request original in
  let* fields=Run_registry_core.Json.object_fields before in
  let* ()=Run_registry_core.Json.exact_fields ~required:["task_id";"status"] fields in
  let* task_id=Run_registry_core.Json.string_field "task_id" fields in
  let* ()=if task_id=request.AR.task_id then Ok () else Error "captured before-state names another Task" in
  let* raw=match List.assoc_opt "status" fields with
    | Some json -> Ok json
    | None -> Error "captured before-state has no Task status" in
  let* status=Masc_domain.task_status_of_yojson raw in
  let* raw=Lane_addon_action.canonical raw in
  let* encoded=Lane_addon_action.canonical (Masc_domain.task_status_to_yojson status) in
  let* ()=if Yojson.Safe.equal raw encoded then Ok ()
    else Error "captured Task status is not its exact canonical metadata" in
  let* strict=Task_status_observation.of_yojson (Task_status_observation.to_yojson status) in
  match strict with
  | Masc_domain.AwaitingVerification awaiting when awaiting.verification_id=V.verification_id original
      && awaiting.assignee=request.agent_name -> Ok status
  | AwaitingVerification _ | Todo | Claimed _ | InProgress _ | Done _ | Cancelled _ ->
    Error "captured before-state differs from original verification and producer"

let before_of_status ~original status =
  let before=`Assoc ["task_id",`String (V.review_request original).AR.task_id;
    "status",Masc_domain.task_status_to_yojson status] in
  let* _=before_status ~original before in Ok before

let decode ~original ~judgment ~authority (change:P.change) =
  let* result,notes = O.judgment_of_json ~original judgment in
  let* original_digest = V.digest original in
  let task_id = (V.review_request original).AR.task_id in
  let verification_id = V.verification_id original in
  let open Yojson.Safe.Util in
  try
    let fields=to_assoc change.after in
    let* ()=if List.sort String.compare (List.map fst fields)=
      ["authority_actor";"notes";"original_digest";"producer";"review";"schema";
       "started_at";"task_id";"verification_id"]
      && member "schema" change.after=`String "verifier_domain_commit/v1"
      && member "original_digest" change.after=`String original_digest
      && member "verification_id" change.after=`String verification_id
      && member "task_id" change.after=`String task_id
      && member "producer" change.after=`String (Verifier_review_original.review_request original).AR.agent_name
      && member "authority_actor" change.after=`String (Masc_domain.completion_authority_actor authority)
      && Yojson.Safe.equal (member "review" change.after) (O.result_to_json result)
      then Ok () else Error "domain commit intent differs from its immutable original" in
    let* ()=if member "notes" change.after=`String notes then Ok ()
      else Error "original commit notes differ from retained host judgment" in
    let started_at=member "started_at" change.after |> to_string in
    let* result=O.result_of_json (member "review" change.after) in
    let* status=before_status ~original change.before in
    let* ()=match status with
      | Masc_domain.AwaitingVerification awaiting when awaiting.started_at=started_at -> Ok ()
      | AwaitingVerification _ | Todo | Claimed _ | InProgress _ | Done _ | Cancelled _ ->
        Error "original commit before-state differs from retained start time" in
    let note=Yojson.Safe.from_string notes in
    let header=member "verification_request" note and review=member "review" note in
    let* ()=if member "id" header=`String verification_id
      && member "task_id" header=`String task_id
      && member "worker" header=`String (Verifier_review_original.review_request original).AR.agent_name
      && member "authority_actor" review=`String (Masc_domain.completion_authority_actor authority)
      && member "authority_kind" review=`String (Masc_domain.completion_authority_kind authority)
      && member "evaluator_runtime" review=`String result.AR.evaluator_runtime
      && member "gate" review=`String (AR.gate_to_string result.gate)
      then Ok () else Error "retained domain notes do not bind original verification and evaluator" in
    let* verdict=match result.AR.verdict with Some verdict -> Ok verdict
      | None -> Error "domain commit intent has no verdict" in
    Ok (notes,started_at,result,verdict)
  with Type_error _ | Undefined _ | Yojson.Json_error _ -> Error "malformed original domain commit intent"

let prepare ~original ~judgment ~authority ~before =
  let* status=before_status ~original before in
  let* started_at=match status with
    | Masc_domain.AwaitingVerification awaiting -> Ok awaiting.started_at
    | Todo | Claimed _ | InProgress _ | Done _ | Cancelled _ ->
      Error "commit capture is not awaiting verification" in
  let* result,notes=O.judgment_of_json ~original judgment in
  let* original_digest=V.digest original in
  let request=V.review_request original in
  let after=`Assoc ["schema",`String "verifier_domain_commit/v1";
    "original_digest",`String original_digest;"verification_id",`String (V.verification_id original);
    "task_id",`String request.AR.task_id;"producer",`String request.agent_name;
    "authority_actor",`String (Masc_domain.completion_authority_actor authority);
    "review",O.result_to_json result;"notes",`String notes;"started_at",`String started_at] in
  let change={P.before;after} in
  let* _=decode ~original ~judgment ~authority change in Ok change
