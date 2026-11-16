module Owner = Lane_addon_tool_request_owner
module Record = Owner.Record
module Progress = Lane_addon_request_progress
module Destination = Lane_addon_captured_destination
module Exact = Lane_addon_exact
module Submit = Lane_addon_submit_once
open Result.Syntax

type replaced = {captured:Destination.t;current:Destination.t}
let replaced_to_json {captured;current} =
  `Assoc ["declaration_replaced",`Assoc
    ["captured",Destination.to_json captured;"current",Destination.to_json current]]
let confirm_replaced ~captured:expected json =
  let context="History declaration-replaced evidence" in
  match json with
  | `Assoc ["declaration_replaced",`Assoc ["captured",captured;"current",current]] ->
    let* captured=Destination.of_json ~context captured in
    let* current=Destination.of_json ~context current in
    let* ()=if captured=expected then Ok ()
      else Error (context ^ " names another captured destination") in
    (match Destination.relation ~captured ~current with
     | Destination.Replaced -> Ok {captured;current}
     | Destination.Same | Destination.Other_owner ->
       Error (context ^ " does not show a replaced declaration"))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ ->
    Error (context ^ " is not the declaration-replaced object")

type ending = Before_admission | Cut_release of Yojson.Safe.t
let evidence ~ending ~original ~(captured:Destination.t) ~(current:Destination.t) =
  let* ()=if Record.installation_id original=captured.installation_id
      && Record.package_id original=captured.package_id && Record.tool original=captured.tool
    then Ok () else Error "Declaration replacement differs from its original destination" in
  let* ()=match Destination.relation ~captured ~current with
    | Destination.Replaced -> Ok ()
    | Same | Other_owner -> Error "Before-admission refusal requires a replacement declaration" in
  match ending with
  | Before_admission -> Ok (replaced_to_json {captured;current})
  | Cut_release refusal ->
  Ok (`Assoc ["refusal",refusal;"version",`Int 1;
    "kind",`String "librarian-cut-declaration-replacement";
    "scope",`String (Record.scope original);"request_id",`String (Record.request_id original);
    "request_digest",`String (Record.request_digest original);"summary",Record.summary original;
    "captured",Destination.to_json captured;"replacement",Destination.to_json current])

let validate ~ending ~original ~captured json =
  let* normalized=Lane_addon_action.canonical json in
  match ending with
  | Before_admission ->
    let* replacement=confirm_replaced ~captured normalized in
    let+ _=evidence ~ending ~original ~captured ~current:replacement.current in ()
  | Cut_release _ ->
  let* fields=match normalized with
    | `Assoc fields -> Ok fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error "Declaration replacement evidence must be an object" in
  let* current=match List.assoc_opt "replacement" fields with
    | Some value -> Destination.of_json ~context:"Declaration replacement" value
    | None -> Error "Declaration replacement evidence has no replacement destination" in
  let* expected=evidence ~ending ~original ~captured ~current in
  let* expected=Lane_addon_action.canonical expected in
  if Yojson.Safe.equal expected normalized then Ok ()
  else Error "Declaration replacement evidence differs from its original record or destinations"

let retained ~original ~captured =
  match Progress.phase (Record.progress original) with
  | Progress.Rejected {stage=Before_dispatch;evidence} ->
    let+ ()=validate ~ending:Before_admission ~original ~captured evidence in true
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
  let* evidence=rejected (evidence ~ending:Before_admission ~original ~captured ~current) in
  match Owner.advance_record ~store ~expected:original
    ~event:(Progress.Refused {stage=Before_dispatch;evidence}) with
  | Ok (Owner.Record_stored record | Record_already_stored record) -> Ok record
  | Ok (Record_unconfirmed detail) -> Error (Submit.Uncertain detail)
  | Error error -> Error (Submit.Unavailable (Owner.update_error_to_string error))

let cut_evidence ~original ~(exact:Exact.request) =
  match Progress.phase (Record.progress original) with
  | Progress.Rejected {stage=Execution;evidence} ->
    let* ()=if exact.request_id=Record.request_id original then Ok ()
      else Error "Cut release names another original request" in
    let* schema=Option.to_result ~none:"Cut original lacks its captured schema" exact.schema in
    let* retained=Exact.retained_final_of_json ~schema evidence in
    (match retained with
     | Exact.Retained_unknown Cut -> Ok (Some evidence)
     | Retained_unknown (Interrupted | Raised) | Retained_call _ | Retained_not_allowed _
     | Retained_request_id_reused -> Ok None)
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Rejected {stage=Before_dispatch;_} | Subdividing _ | Subdivided _ -> Ok None

let confirm_host_cut ~store ~original ~(exact:Exact.request) =
  let* installation=Owner.installation_of_id (Record.installation_id original) in
  let* declaration_id=match installation with Owner.Configuration id -> Ok id
    | Manual _ -> Error "Cut release requires a configured original" in
  let* schema=Option.to_result ~none:"Cut original lacks its captured schema" exact.schema in
  (* A concurrent retained-final replay may own the claim, so recovery can
     observe only the record. Independently bind every completed proof too. *)
  let* observed=Exact.recover_retained ~store ~declaration_id ~schema exact
    |> Result.map_error Exact.describe_recovery_error in
  match observed with
  | Exact.Retained_terminal (Retained_unknown Cut) ->
    let* latest=Exact.read_latest_original_execution ~store ~declaration_id ~schema exact in
    (match latest with
     | Exact.No_completed_latest -> Ok ()
     | Completed_latest _ -> Error "Cut replacement has a completed original execution")
  | Retained_absent | Retained_open
  | Retained_terminal (Retained_unknown (Interrupted | Raised) | Retained_call _
    | Retained_not_allowed _ | Retained_request_id_reused) ->
    Error "Cut replacement is not confirmed by its original host record and proofs"

let released_cut_payload ~original ~exact ~captured =
  match Progress.settlement (Record.progress original) with
  | None -> Ok false
  | Some disposition ->
    let* refusal=cut_evidence ~original ~exact in
    (match refusal with
     | None -> Ok false
     | Some refusal ->
       let+ ()=validate ~ending:(Cut_release refusal) ~original ~captured disposition in true)

let released_cut ~store ~original ~exact ~captured =
  let* released=released_cut_payload ~original ~exact ~captured in
  if not released then Ok false else
  let+ ()=confirm_host_cut ~store ~original ~exact in true

let release_cut ~store ~original ~exact ~captured ~current =
  let rejected result=Result.map_error (fun detail -> Submit.Rejected detail) result in
  let* refusal=rejected (cut_evidence ~original ~exact) in
  let* refusal=Option.to_result ~none:(Submit.Rejected "Only an original Cut refusal may be released") refusal in
  let* ()=rejected (confirm_host_cut ~store ~original ~exact) in
  let* disposition=rejected (evidence ~ending:(Cut_release refusal) ~original ~captured ~current) in
  match Owner.advance_record ~store ~expected:original ~event:(Progress.Refusal_settled disposition) with
  | Ok (Owner.Record_stored record | Record_already_stored record) -> Ok record
  | Ok (Record_unconfirmed detail) -> Error (Submit.Uncertain detail)
  | Error error -> Error (Submit.Unavailable (Owner.update_error_to_string error))

let ended_payload ~original ~(exact:Exact.request) ~captured =
  let* ()=if exact.request_id=Record.request_id original then Ok ()
    else Error "Declaration ending names another original request" in
  match Progress.phase (Record.progress original) with
  | Progress.Rejected {stage=Before_dispatch;_} -> retained ~original ~captured
  | Rejected {stage=Execution;evidence} ->
    let* schema=Option.to_result ~none:"Declaration ending lacks its original schema" exact.schema in
    let* final=Exact.retained_final_of_json ~schema evidence in
    (match final with
     | Exact.Retained_not_allowed {reason=Replaced_declaration} -> Ok true
     | Retained_unknown Cut -> released_cut_payload ~original ~exact ~captured
     | Retained_unknown (Interrupted | Raised) | Retained_call _ | Retained_not_allowed {reason=Permission_refused _}
     | Retained_request_id_reused -> Ok false)
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> Ok false

type ending_reads = {
  before_dispatch : unit -> (unit, string) result;
  observe : unit -> (Exact.retained_observation, string) result;
  latest : unit -> (Exact.latest_original_execution, string) result;
}
type host_ending = Cut_ending | Declaration_ending
let host_ending = function
  | Exact.Retained_unknown Cut -> Some Cut_ending
  | Retained_not_allowed {reason=Replaced_declaration} -> Some Declaration_ending
  | Retained_unknown (Interrupted | Raised) | Retained_call _ | Retained_not_allowed {reason=Permission_refused _}
  | Retained_request_id_reused -> None

let ended_with ~reads ~original ~exact ~captured =
  let* permitted=ended_payload ~original ~exact ~captured in
  if not permitted then Ok false else
  match Progress.phase (Record.progress original) with
  | Progress.Rejected {stage=Before_dispatch;_} ->
    let+ ()=reads.before_dispatch () in true
  | Rejected {stage=Execution;evidence} ->
    let* schema=Option.to_result ~none:"Declaration ending lacks its original schema" exact.Exact.schema in
    let* final=Exact.retained_final_of_json ~schema evidence in
    let* observed=reads.observe () in
    let expected=host_ending final in
    let actual=match observed with
      | Exact.Retained_terminal retained -> host_ending retained
      | Retained_absent | Retained_open -> None in
    let* ()=if Option.is_some expected && expected=actual then Ok ()
      else Error "Declaration ending differs from its original host record" in
    (* This read is independent of record recovery, including a busy claim. *)
    let* latest=reads.latest () in
    (match latest with
     | Exact.No_completed_latest -> Ok true
     | Completed_latest _ -> Error "Declaration ending has a completed original execution")
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> Ok false

let ended ~store ~original ~exact ~captured =
  let target () =
    let* installation=Owner.installation_of_id (Record.installation_id original) in
    let* declaration_id=match installation with
      | Owner.Configuration id -> Ok id
      | Manual _ -> Error "Declaration ending requires a configured original" in
    let+ schema=Option.to_result ~none:"Declaration ending lacks its original schema" exact.Exact.schema in
    declaration_id,schema in
  let reads={
    before_dispatch=(fun () -> confirm_no_execution ~store ~original ~exact_digest:(Exact.digest exact));
    observe=(fun () ->
      let* declaration_id,schema=target () in
      Exact.recover_retained ~store ~declaration_id ~schema exact
      |> Result.map_error Exact.describe_recovery_error);
    latest=(fun () ->
      let* declaration_id,schema=target () in
      Exact.read_latest_original_execution ~store ~declaration_id ~schema exact);
  } in
  ended_with ~reads ~original ~exact ~captured
