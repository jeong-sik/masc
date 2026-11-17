module Original = Keeper_media_reading_original
module Approval = Lane_addon_request_approval
module Fingerprint = Keeper_approval_request_fingerprint
module Progress = Lane_addon_request_progress
open Result.Syntax

let input original =
  `Assoc
    [ "schema", `String "keeper-media-reading-approval.v1"
    ; "request_id", `String (Original.request_id original)
    ; "request_digest", `String (Original.original_digest original)
    ; "execution_id", `String (Original.execution_id original)
    ]

let intent original =
  let subject = Original.original_subject original in
  let* request = Fingerprint.exact_request
      ~base_path:(Original.subject_base_path subject)
      ~keeper_name:(Original.subject_keeper_name subject)
      ~operation:Keeper_gate.media_read_gate_operation ~input:(input original)
      ~origin:(Original.origin original) ~task_id:(Original.task_id original)
      ~goal_id:None ~continuation_channel:(Original.continuation_channel original) in
  Approval.intent ~request_id:(Original.request_id original)
    ~request_digest:(Original.original_digest original) ~request

let validate_progress ~original progress =
  let* expected = intent original in
  let* _has_intent = List.fold_left (fun checked event ->
    let* has_intent = checked in
    match event with
    | Progress.Approval_intended observed ->
      if Approval.equal_intent expected observed then Ok true
      else Error "media approval intent differs from its complete original"
    | Progress.Approval_wait_retained wait ->
      if has_intent && Approval.wait_matches_intent expected wait then Ok true
      else Error "media approval wait differs from its original intent"
    | Progress.Dispatch_intended ->
      if has_intent then Ok true
      else Error "media dispatch has no retained original approval intent"
    | Progress.Admission_declined _ | Progress.Execution_observed _
    | Progress.Judgment_retained _ | Progress.Preparation_intended _
    | Progress.Preparation_observed _ | Progress.Replacement_intended _
    | Progress.Replacement_observed _ | Progress.Commit_intended _
    | Progress.Commit_uncertain _ | Progress.Commit_retry_observed _
    | Progress.Commit_observed _ | Progress.Commit_conflicted _
    | Progress.Refused _ | Progress.Refusal_settled _
    | Progress.Successor_intended _ | Progress.Successor_observed _
    | Progress.Observer _ -> Ok has_intent)
      (Ok false) (Progress.events progress) in
  Ok ()
