module Artifacts = Published_artifact_store
open Result.Syntax

type cursor = { after_id : string; snapshot : string }
type query = { text : string; cursor : cursor option }

let fields allowed = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length names <> List.length (List.sort_uniq String.compare names)
       || List.exists (fun name -> not (List.mem name allowed)) names
    then Error "duplicate or unknown artifact discovery field"
    else Ok fields
  | _ -> Error "expected an artifact discovery object"

let cursor_of_json json =
  let* fields = fields ["after_id"; "snapshot"] json in
  match List.assoc_opt "after_id" fields, List.assoc_opt "snapshot" fields with
  | Some (`String after_id), Some (`String snapshot)
    when Published_artifact.valid_id after_id
         && Result.is_ok (Tool_blob_store.validate_sha256 snapshot) ->
    Ok { after_id; snapshot }
  | _ -> Error "invalid artifact search cursor"

let query_of_json json =
  let* fields = fields ["action"; "query"; "cursor"] json in
  let* text = match List.assoc_opt "query" fields with
    | Some (`String text) when String.is_valid_utf_8 text -> Ok (String.trim text)
    | _ -> Error "query must be a UTF-8 string" in
  let* cursor = match List.assoc_opt "cursor" fields with
    | None -> Ok None
    | Some json -> let* cursor = cursor_of_json json in Ok (Some cursor) in
  Ok { text; cursor }

let published_id_of_json json =
  let* fields = fields ["action"; "artifact_id"] json in
  match List.assoc_opt "artifact_id" fields with
  | Some (`String id) when Published_artifact.valid_id id -> Ok id
  | _ -> Error "published requires a valid artifact_id"

let fail class_ message =
  Keeper_tool_execution.failure ~class_ ~effect_disposition:Tool_result.Proven_pre_effect message

let entry = function
  | `Assoc fields as json ->
    (match List.assoc_opt "id" fields, List.assoc_opt "revision" fields with
     | Some (`String id), Some (`Int revision)
       when Published_artifact.valid_id id && revision > 0 -> Ok (id, revision, json)
     | _ -> Error "invalid published artifact inventory entry")
  | _ -> Error "invalid published artifact inventory entry"

let entries items =
  List.fold_left (fun result json ->
    let* accumulated = result in
    let* item = entry json in
    Ok (item :: accumulated)) (Ok []) items
  |> Result.map List.rev

let metadata = function
  | `Assoc fields -> `Assoc (List.filter (fun (name, _) -> name <> "body") fields)
  | json -> json

let matches text (_, _, json) =
  if text = "" then true
  else match json with
    | `Assoc fields ->
      let values = List.filter_map (fun name ->
        match List.assoc_opt name fields with
        | Some (`String value) -> Some value
        | Some (`List values) ->
          Some (String.concat "\n" (List.filter_map (function `String value -> Some value | _ -> None) values))
        | Some _ | None -> None)
        ["title"; "summary"; "authors"; "task_id"; "goal_id"] in
      String_util.contains_all_tokens_ci (String.concat "\n" values) text
    | _ -> false

let snapshot text entries diagnostics =
  let diagnostics = List.sort compare diagnostics |> List.map (fun (id, message) ->
    `Assoc ["id", `String id; "error", `String message]) in
  let data = `Assoc ["query", `String text;
    "artifacts", `List (List.map (fun (_, _, json) -> json) entries);
    "diagnostics", `List diagnostics] in
  Agent_core_sha256.(to_hex (digest_string (Yojson.Safe.to_string data)))

let cursor_json snapshot after_id =
  `Assoc ["after_id", `String after_id; "snapshot", `String snapshot]

let page_json ~unreadable_count ~snapshot ~after rows =
  `Assoc ["schema", `String "masc.artifact_discovery.v1";
    "artifacts", `List rows;
    "unreadable_count", `Int unreadable_count;
    "next_cursor", (match after with None -> `Null | Some id -> cursor_json snapshot id)]

let compact id revision =
  `Assoc ["id", `String id; "revision", `Int revision; "metadata_omitted", `Bool true]

let page ~unreadable_count ~snapshot items =
  let fits rows after =
    String.length (Yojson.Safe.to_string (page_json ~unreadable_count ~snapshot ~after rows))
    <= Common.max_tool_result_wire_bytes in
  let rec loop reversed = function
    | [] -> page_json ~unreadable_count ~snapshot ~after:None (List.rev_map snd reversed)
    | (id, revision, json) :: rest ->
      let row = metadata json in
      let after = match rest with [] -> None | _ :: _ -> Some id in
      let rows = List.rev_map snd ((id, row) :: reversed) in
      if fits rows after then loop ((id, row) :: reversed) rest
      else match reversed with
        | [] -> page_json ~unreadable_count ~snapshot ~after [compact id revision]
        | (previous_id, _) :: _ ->
          page_json ~unreadable_count ~snapshot ~after:(Some previous_id) (List.rev_map snd reversed)
  in
  loop [] items

let find ~base_path query = Eio_unix.run_in_systhread (fun () ->
  match Artifacts.list_with_authors ~base_path with
  | Error error -> fail Tool_result.Runtime_failure (Artifacts.error_message error)
  | Ok listing ->
    match entries listing.artifacts with
    | Error message -> fail Tool_result.Runtime_failure message
    | Ok entries ->
      let entries = List.sort (fun (left, _, _) (right, _, _) -> String.compare left right) entries in
      let candidates = List.filter (matches query.text) entries in
      let current_snapshot = snapshot query.text candidates listing.diagnostics in
      match query.cursor with
      | Some cursor when not (String.equal cursor.snapshot current_snapshot) ->
        fail Tool_result.Workflow_rejection "The matching artifacts, catalog diagnostics or query changed; restart the search."
      | Some cursor when not (List.exists (fun ((id, _, _) as item) ->
          String.equal id cursor.after_id && matches query.text item) candidates) ->
        fail Tool_result.Workflow_rejection "The artifact search cursor is not a result of this query; restart the search."
      | cursor ->
        let candidates = List.filter (fun ((id, _, _) as item) ->
          matches query.text item && match cursor with
          | None -> true
          | Some cursor -> String.compare id cursor.after_id > 0) candidates in
        page ~unreadable_count:(List.length listing.diagnostics) ~snapshot:current_snapshot candidates
        |> Keeper_tool_execution.success_data)

let published ~base_path ~id = Eio_unix.run_in_systhread (fun () ->
  let start_time = Tool_timing.start () in
  match Artifacts.read ~base_path ~id ~revision:None with
  | Error (Artifacts.Invalid message) -> fail Tool_result.Policy_rejection message
  | Error ((Artifacts.Missing | Artifacts.Conflict _) as error) ->
    fail Tool_result.Workflow_rejection (Artifacts.error_message error)
  | Error ((Artifacts.Unavailable _ | Artifacts.Commit_uncertain _) as error) ->
    fail Tool_result.Runtime_failure (Artifacts.error_message error)
  | Ok (artifact, revision, content) ->
    let data = `Assoc [
      "artifact", Published_artifact.summary_to_json ~id:artifact.id revision;
      "content", `String content;
      "revisions", `List (List.map Published_artifact.revision_to_json artifact.revisions)] in
    let result = Tool_result.make_ok ~tool_name:"keeper_artifact_draft" ~start_time ~data () in
    match Tool_bridge.attach_artifact_manifest ~projection:Tool_output.Inline_with_reference ~base_path result with
    | Ok result -> Keeper_tool_execution.of_tool_result result
    | Error _ -> fail Tool_result.Runtime_failure "The published artifact was read, but its result manifest could not be stored.")
