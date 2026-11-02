module Manifest = Keeper_runtime_manifest
module Scan = Server_dashboard_http_keeper_runtime_manifest_scan
module Source_outcomes = Keeper_reaction_ledger_source_outcomes

type unavailable =
  | Exact_turn_required
  | Ambiguous_turn_start
  | Incomplete_manifest
  | Missing_turn_start
  | Intake_not_recorded
  | Invalid_intake_sources

let unavailable_to_string = function
  | Exact_turn_required -> "exact_turn_required"
  | Ambiguous_turn_start -> "ambiguous_turn_start"
  | Incomplete_manifest -> "incomplete_manifest"
  | Missing_turn_start -> "missing_turn_start"
  | Intake_not_recorded -> "intake_not_recorded"
  | Invalid_intake_sources -> "invalid_intake_sources"

let select_sources ~keeper_name ~trace_id ~turn_id (scan : Scan.runtime_manifest_scan) =
  match turn_id with
  | None -> Error Exact_turn_required
  | Some turn when turn <= 0 -> Error Exact_turn_required
  | Some turn ->
    let starts = Scan.queue_to_list scan.returned_rows
      |> List.filter (fun (row : Manifest.t) -> row.event = Manifest.Turn_started) in
    let count = Scan.runtime_manifest_scan_event_count scan Manifest.Turn_started in
    if count > 1 || List.length starts > 1 then Error Ambiguous_turn_start
    else if scan.scanned_lines >= scan.scan_line_limit
         || scan.invalid_manifest_row_count > 0 || scan.invalid_json_row_count > 0
         || scan.unsupported_event_unattributed_count > 0
    then Error Incomplete_manifest
    else match starts with
      | [row] when count = 1 && String.equal row.keeper_name keeper_name
                   && String.equal row.trace_id trace_id && row.keeper_turn_id = Some turn ->
        (match row.decision with
         | `Assoc fields ->
           (match List.filter (fun (key, _) -> String.equal key "intake_sources") fields with
            | [(_, json)] ->
              (match Source_outcomes.selections_of_yojson json with
               | Some sources -> Ok sources
               | None -> Error Invalid_intake_sources)
            | [] -> Error Intake_not_recorded
            | _ :: _ -> Error Invalid_intake_sources)
         | _ -> Error Intake_not_recorded)
      | [] when count = 0 -> Error Missing_turn_start
      | [] | _ :: _ -> Error Incomplete_manifest

let project ~config ~keeper_name ~trace_id ~turn_id scan =
  match select_sources ~keeper_name ~trace_id ~turn_id scan with
  | Error reason ->
    `Assoc
      [ "schema", `String Source_outcomes.schema
      ; "observed_at", `Float (Unix.gettimeofday ())
      ; "state", `String "unavailable"
      ; "reason", `String (unavailable_to_string reason)
      ]
  | Ok sources ->
    Source_outcomes.observe ~base_path:config.Workspace.base_path ~keeper_name sources
