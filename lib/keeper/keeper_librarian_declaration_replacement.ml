module Owner = Lane_addon_tool_request_owner
module Record = Owner.Record
module Progress = Lane_addon_request_progress
module Destination = Lane_addon_captured_destination
module Exact = Lane_addon_exact
module Submit = Lane_addon_submit_once
open Result.Syntax

let evidence ~original ~(captured:Destination.t) ~(current:Destination.t) =
  let* ()=if Record.installation_id original=captured.installation_id
      && Record.package_id original=captured.package_id && Record.tool original=captured.tool
    then Ok () else Error "Declaration replacement differs from its original destination" in
  let* ()=match Destination.relation ~captured ~current with
    | Destination.Replaced -> Ok ()
    | Same | Other_owner -> Error "Before-admission refusal requires a replacement declaration" in
  Ok (`Assoc ["version",`Int 1;"kind",`String "librarian-declaration-replacement";
    "scope",`String (Record.scope original);"request_id",`String (Record.request_id original);
    "request_digest",`String (Record.request_digest original);"summary",Record.summary original;
    "captured",Destination.to_json captured;"replacement",Destination.to_json current])

let validate ~original ~captured json =
  let* normalized=Lane_addon_action.canonical json in
  let* fields=match normalized with
    | `Assoc fields -> Ok fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error "Declaration replacement evidence must be an object" in
  let* current=match List.assoc_opt "replacement" fields with
    | Some value -> Destination.of_json ~context:"Declaration replacement" value
    | None -> Error "Declaration replacement evidence has no replacement destination" in
  let* expected=evidence ~original ~captured ~current in
  let* expected=Lane_addon_action.canonical expected in
  if Yojson.Safe.equal expected normalized then Ok ()
  else Error "Declaration replacement evidence differs from its original record or destinations"

let retained ~original ~captured =
  match Progress.phase (Record.progress original) with
  | Progress.Rejected {stage=Before_dispatch;evidence} ->
    let+ ()=validate ~original ~captured evidence in true
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Rejected {stage=Execution;_} | Subdividing _ | Subdivided _ -> Ok false

let confirm_no_execution ~store ~original ~exact_digest =
  let* installation=Owner.installation_of_id (Record.installation_id original) in
  let* declaration_id=match installation with
    | Owner.Configuration id -> Ok id
    | Manual _ -> Error "Declaration replacement requires a configured original" in
  let identity=Exact.identity_of_digest ~request_id:(Record.request_id original) ~digest:exact_digest in
  let* observed=Exact.observe_open ~store ~declaration_id identity
    |> Result.map_error Exact.describe_recovery_error in
  match observed with
  | Exact.No_record -> Ok ()
  | Open | Needs_request -> Error "A pre-admission replacement has original host execution evidence"

let refuse ~store ~original ~exact_digest ~captured ~current =
  let rejected result=Result.map_error (fun detail -> Submit.Rejected detail) result in
  let* ()=rejected (match Progress.phase (Record.progress original) with
    | Progress.Captured | Admission_wait _ -> Ok ()
    | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _ | Finished _
    | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
      Error "Only an unadmitted original can end before dispatch") in
  let* ()=rejected (confirm_no_execution ~store ~original ~exact_digest) in
  let* evidence=rejected (evidence ~original ~captured ~current) in
  match Owner.advance_record ~store ~expected:original
    ~event:(Progress.Refused {stage=Before_dispatch;evidence}) with
  | Ok (Owner.Record_stored record | Record_already_stored record) -> Ok record
  | Ok (Record_unconfirmed detail) -> Error (Submit.Uncertain detail)
  | Error error -> Error (Submit.Unavailable (Owner.update_error_to_string error))
