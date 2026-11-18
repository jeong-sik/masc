module Remote = Keeper_sandbox_remote
module Wire = Exec_ssh_protocol
module Original = Keeper_media_reading_original
module Progress = Lane_addon_request_progress
open Result.Syntax

type t = { value : Remote.execution_observation; bytes : string }
let mime_type = "application/json"
let schema = "keeper-media-reading-transport.v1"
let bytes (value : t) = value.bytes
let observation (value : t) = value.value
let request_not_sent (value : t) = match value.value with
  | Remote.Execution_unavailable Remote.Request_not_sent -> true
  | Remote.Execution_observed _
  | Remote.Execution_unavailable (Remote.Transport_unavailable _ | Remote.Peer_receipt_missing
      | Remote.Invalid_receipt _ | Remote.Shim_refused_without_receipt) -> false

let fields names = function
  | `Assoc values when List.sort String.compare (List.map fst values)
      = List.sort String.compare names -> Ok values
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "invalid media transport fields"
let text values key = Json_util.require_field_string ~surface:schema key values
let bool values key = match List.assoc_opt key values with
  | Some (`Bool value) -> Ok value
  | Some (`Null | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _) | None ->
    Error ("media transport requires boolean " ^ key)
let require condition detail = if condition then Ok () else Error detail
let encode value =
  let body = match value with
    | Remote.Execution_observed (receipt,trailer) ->
      ["status",`String "observed";
       "frame",`String (Wire.render_trailer ~execution_receipt:receipt trailer)]
    | Remote.Execution_unavailable reason ->
      let reason,detail = match reason with
        | Remote.Request_not_sent -> "request_not_sent",[]
        | Remote.Transport_unavailable acceptance ->
          let acceptance = match acceptance with
            | Remote.Acceptance_not_asked -> "not_asked"
            | Remote.Acceptance_not_read -> "not_read"
            | Remote.Acceptance_read -> "read" in
          "transport_unavailable",["acceptance",`String acceptance]
        | Remote.Peer_receipt_missing -> "peer_receipt_missing",[]
        | Remote.Invalid_receipt detail -> "invalid_receipt",["detail",`String detail]
        | Remote.Shim_refused_without_receipt -> "shim_refused_without_receipt",[] in
      ["status",`String "unavailable";"reason",`String reason] @ detail in
  `Assoc (("schema",`String schema)::body)

let decode json =
  let* values = match json with
    | `Assoc values -> Ok values
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error "media transport must be an object" in
  let* version = text values "schema" in
  let* () = require (version=schema) "unknown media transport schema" in
  let* status = text values "status" in
  match status with
  | "observed" ->
    let* values = fields ["schema";"status";"frame"] json in
    let* frame = text values "frame" in
    let* trailer = Wire.parse_trailer frame in
    let* receipt = Wire.parse_execution_receipt frame in
    let* receipt = Option.to_result ~none:"observed transport has no execution receipt" receipt in
    let+ () = require (frame=Wire.render_trailer ~execution_receipt:receipt trailer)
        "retained transport frame differs from its complete canonical observation" in
    Remote.Execution_observed (receipt,trailer)
  | "unavailable" ->
    let* reason = text values "reason" in
    let plain reason =
      let+ _ = fields ["schema";"status";"reason"] json in
      Remote.Execution_unavailable reason in
    (match reason with
     | "request_not_sent" -> plain Remote.Request_not_sent
     | "peer_receipt_missing" -> plain Remote.Peer_receipt_missing
     | "shim_refused_without_receipt" -> plain Remote.Shim_refused_without_receipt
     | "invalid_receipt" ->
       let* values = fields ["schema";"status";"reason";"detail"] json in
       let+ detail = text values "detail" in
       Remote.Execution_unavailable (Remote.Invalid_receipt detail)
     | "transport_unavailable" ->
       let* values = fields ["schema";"status";"reason";"acceptance"] json in
       let* acceptance = text values "acceptance" in
       let+ acceptance = match acceptance with
         | "not_asked" -> Ok Remote.Acceptance_not_asked
         | "not_read" -> Ok Remote.Acceptance_not_read
         | "read" -> Ok Remote.Acceptance_read
         | _ -> Error "unknown retained transport acceptance evidence" in
       Remote.Execution_unavailable (Remote.Transport_unavailable acceptance)
     | _ -> Error "unknown retained transport unavailability")
  | _ -> Error "unknown retained transport status"

let capture value =
  let* json = Lane_addon_json.canonical (encode value) in
  let* decoded = decode json in
  let+ () = require (value=decoded) "transport observation does not roundtrip completely" in
  { value; bytes=Yojson.Safe.to_string json }
let restore_bytes bytes =
  let* json = try Ok (Yojson.Safe.from_string bytes)
    with Yojson.Json_error detail -> Error ("invalid retained transport JSON: " ^ detail) in
  let* json = Lane_addon_json.canonical json in
  let* value = decode json in
  let+ () = require (bytes=Yojson.Safe.to_string json) "retained transport bytes are not canonical" in
  { value; bytes }

type link = { reference : Tool_output.artifact_ref; not_sent : bool; json : Yojson.Safe.t }
let link_schema = "keeper-media-reading-transport-link.v1"
let artifact (link : link) = link.reference
let link_to_json (link : link) = link.json
let link_request_not_sent (link : link) = link.not_sent
let make_link ~original ~not_sent (reference : Tool_output.artifact_ref) =
  let* () = require (reference.mime=mime_type && reference.bytes>0 && reference.preview=""
      && Option.is_none reference.answer_fingerprint) "invalid normalized media transport artifact" in
  let+ json = Lane_addon_json.canonical (`Assoc
    ["schema",`String link_schema;"request_id",`String (Original.request_id original);
     "request_digest",`String (Original.original_digest original);
     "execution_id",`String (Original.execution_id original);"request_not_sent",`Bool not_sent;
     "artifact",Tool_output.normalized_artifact_ref_to_json reference]) in
  { reference; not_sent; json }
let link ~original ~captured reference =
  make_link ~original ~not_sent:(request_not_sent captured) reference
let link_of_json ~original json =
  let* json = Lane_addon_json.canonical json in
  let* values = fields ["schema";"request_id";"request_digest";"execution_id";
    "request_not_sent";"artifact"] json in
  let* () = List.fold_left (fun checked (key,expected) ->
    let* () = checked in let* actual = text values key in
    require (actual=expected) ("media transport link differs in " ^ key)) (Ok ())
    ["schema",link_schema;"request_id",Original.request_id original;
     "request_digest",Original.original_digest original;"execution_id",Original.execution_id original] in
  let* not_sent = bool values "request_not_sent" in
  let* reference = match Tool_output.normalized_artifact_ref_of_json (List.assoc "artifact" values) with
    | Tool_output.Decoded_normalized_artifact_ref reference -> Ok reference
    | Tool_output.Invalid_normalized_artifact_ref {detail} -> Error detail
    | Tool_output.Not_normalized_artifact_ref -> Error "transport link has no normalized artifact" in
  let* link = make_link ~original ~not_sent reference in
  let+ () = require (Yojson.Safe.equal json link.json) "transport link is not canonical" in
  link
let check_value link value =
  require (link.not_sent=request_not_sent value) "transport no-send evidence differs from its link"

let validate_progress ~original progress =
  let+ link,_,_ = List.fold_left (fun checked event ->
    let* link,dispatched,replied = checked in
    match event with
    | Progress.Transport_observed json ->
      let* () = require (Option.is_none link) "duplicate media transport observation" in
      let* link = link_of_json ~original json in
      let* () = require (link.not_sent || dispatched) "possibly-sent transport has no dispatch fact" in
      let+ () = require (not (link.not_sent && replied)) "reply contradicts transport Request_not_sent" in
      Some link,dispatched,replied
    | Progress.Dispatch_intended ->
      let+ () = require (Option.is_none link) "observed media invocation cannot be dispatched again" in
      link,true,replied
    | Progress.Judgment_retained _ ->
      let+ () = require (not (Option.exists link_request_not_sent link))
        "reply contradicts transport Request_not_sent" in
      link,dispatched,true
    | Progress.Approval_intended _ | Progress.Approval_wait_retained _
    | Progress.Admission_declined _ | Progress.Execution_observed _
    | Progress.Preparation_intended _ | Progress.Preparation_observed _
    | Progress.Replacement_intended _ | Progress.Replacement_observed _
    | Progress.Commit_intended _ | Progress.Commit_uncertain _ | Progress.Commit_retry_observed _
    | Progress.Commit_observed _ | Progress.Commit_conflicted _ | Progress.Refused _
    | Progress.Refusal_settled _ | Progress.Successor_intended _ | Progress.Successor_observed _
    | Progress.Observer _ -> Ok (link,dispatched,replied))
    (Ok (None,false,false)) (Progress.events progress) in
  link
