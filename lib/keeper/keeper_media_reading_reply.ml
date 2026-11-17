module Original = Keeper_media_reading_original
module Progress = Lane_addon_request_progress
module Sdk_types = Agent_core_protocol.Mcp_schema.Sdk_types
open Result.Syntax

type t = { json : Yojson.Safe.t; bytes : string }

let mime_type = "application/json"

let canonical_reply json =
  let* json = Lane_addon_json.canonical json in
  Ok { json; bytes = Yojson.Safe.to_string json }

let capture_sdk_reply reply = canonical_reply (Sdk_types.tool_result_to_yojson reply)
let reply_json (reply : t) = reply.json
let reply_bytes (reply : t) = reply.bytes

let restore_reply_bytes bytes =
  let* json =
    try Ok (Yojson.Safe.from_string bytes)
    with Yojson.Json_error detail -> Error ("invalid retained media reply JSON: " ^ detail)
  in
  let* reply = canonical_reply json in
  if String.equal reply.bytes bytes then Ok reply
  else Error "retained media reply bytes are not canonical JSON"

type link = { reference : Tool_output.artifact_ref; json : Yojson.Safe.t }

let schema = "keeper-media-reading-reply.v1"

let check_reference (reference : Tool_output.artifact_ref) =
  if not (String.equal reference.mime mime_type) then
    Error "media reply reference must use ordinary application/json"
  else if reference.bytes <= 0 then
    Error "media reply reference must name nonempty canonical JSON bytes"
  else if not (String.equal reference.preview "") then
    Error "media reply reference must have an empty preview"
  else match reference.answer_fingerprint with
    | Some _ -> Error "media reply reference must not carry an answer fingerprint"
    | None -> Ok ()

let link ~original reference =
  let* () = check_reference reference in
  let* json = Lane_addon_json.canonical (`Assoc
    [ "schema", `String schema
    ; "request_id", `String (Original.request_id original)
    ; "request_digest", `String (Original.original_digest original)
    ; "execution_id", `String (Original.execution_id original)
    ; "artifact", Tool_output.normalized_artifact_ref_to_json reference
    ]) in
  Ok { reference; json }

let artifact (link : link) = link.reference
let link_to_json (link : link) = link.json

let fields = function
  | `Assoc values ->
    let keys = ["schema"; "request_id"; "request_digest"; "execution_id"; "artifact"] in
    let* () = Json_util.reject_unknown_fields ~surface:schema ~allowed:keys values in
    if List.length keys = List.length values then Ok values
    else Error "media reply link has missing fields"
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "media reply link must be an object"

let check_text values key expected =
  let* actual = Json_util.require_field_string ~surface:schema key values in
  if String.equal actual expected then Ok ()
  else Error ("media reply link has a different " ^ key)

let link_of_json ~original json =
  let* json = Lane_addon_json.canonical json in
  let* values = fields json in
  let* () = check_text values "schema" schema in
  let* () = check_text values "request_id" (Original.request_id original) in
  let* () = check_text values "request_digest" (Original.original_digest original) in
  let* () = check_text values "execution_id" (Original.execution_id original) in
  let* reference =
    match Tool_output.normalized_artifact_ref_of_json (List.assoc "artifact" values) with
    | Tool_output.Decoded_normalized_artifact_ref reference -> Ok reference
    | Tool_output.Invalid_normalized_artifact_ref { detail } -> Error detail
    | Tool_output.Not_normalized_artifact_ref -> Error "media reply link has no normalized artifact reference"
  in
  let* value = link ~original reference in
  if Yojson.Safe.equal value.json json then Ok value
  else Error "media reply link differs from its canonical reference"

let validate_progress ~original progress =
  let* retained = List.fold_left (fun checked event ->
    let* retained = checked in
    match event with
    | Progress.Judgment_retained json ->
      let* link = link_of_json ~original json in
      Ok (Some link)
    | Progress.Transport_observed _ | Progress.Approval_intended _ | Progress.Approval_wait_retained _
    | Progress.Dispatch_intended | Progress.Admission_declined _
    | Progress.Execution_observed _ | Progress.Preparation_intended _
    | Progress.Preparation_observed _ | Progress.Replacement_intended _
    | Progress.Replacement_observed _ | Progress.Commit_intended _
    | Progress.Commit_uncertain _ | Progress.Commit_retry_observed _
    | Progress.Commit_observed _ | Progress.Commit_conflicted _
    | Progress.Refused _ | Progress.Refusal_settled _
    | Progress.Successor_intended _ | Progress.Successor_observed _
    | Progress.Observer _ -> Ok retained)
    (Ok None) (Progress.events progress) in
  match Progress.phase progress with
  | Progress.Judged _ | Progress.Committing _ | Progress.Commit_unknown _
  | Progress.Finished _ | Progress.Conflicted _ ->
    (match retained with
     | Some _ -> Ok retained
     | None -> Error "media judgment or commit phase has no retained reply link")
  | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _
  | Progress.Rejected _ | Progress.Subdividing _ | Progress.Subdivided _ -> Ok retained
