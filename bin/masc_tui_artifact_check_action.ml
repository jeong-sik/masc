module Check = Masc.Published_artifact_check
module Catalog = Masc_tui_resource_catalog
module Checks = Masc_tui_artifact_checks

type request = { report : Catalog.report; checked : bool;
  expected_change_id : string option; owner : unit ref }

let prepare inventory report = match Checks.resolve inventory report with
  | Unknown detail -> Error ("Refresh confirmations before changing this revision: " ^ detail)
  | Known previous ->
    let checked, expected_change_id = match previous with
      | None -> true, None
      | Some check -> check.state = Check.Unchecked, Some check.change_id in
    Ok {report; checked; expected_change_id; owner=ref ()}

let same_request left right = left.owner == right.owner

let body ~expected_workspace request =
  let path = Masc.Tui_decode.Canonical_path.to_string in
  `Assoc ["expected_workspace", `Assoc
    ["base_path", `String (path expected_workspace.Masc.Tui_decode.sid_base_path);
     "masc_root", `String (path expected_workspace.sid_masc_root)];
    "id", `String request.report.id;
    "revision", `Int request.report.revision.revision;
    "body_sha256", `String request.report.revision.body.sha256;
    "checked", `Bool request.checked;
    "expected_change_id", Option.fold ~none:`Null ~some:(fun id -> `String id) request.expected_change_id]

let decode_response request json =
  let ( let* ) = Result.bind in
  let* check = match json with
    | `Assoc ["check", check] -> Check.of_json check
    | _ -> Error "invalid confirmation change response" in
  if check.target.id <> request.report.id
     || check.target.revision <> request.report.revision.revision
     || check.target.body_sha256 <> request.report.revision.body.sha256
     || (check.state = Check.Checked) <> request.checked
     || Some check.change_id = request.expected_change_id
  then Error "confirmation response does not match the requested change"
  else Ok check
