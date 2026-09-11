type input_source = Approval_evidence of string | Answered_ask of string
type identity = { source : input_source; evidence_fingerprint : string }

type error =
  | Invalid_identity
  | Invalid_input
  | Malformed_marker
  | Conflicting_evidence
  | Duplicate_admission

let error_to_string = function
  | Invalid_identity -> "approval admission identity is empty"
  | Invalid_input -> "approval admission requires an untagged user message"
  | Malformed_marker -> "approval admission message marker is malformed"
  | Conflicting_evidence -> "approval admission evidence conflicts with persisted input"
  | Duplicate_admission -> "approval input is admitted more than once"

let identity ~approval_id ~evidence_fingerprint =
  if String.trim approval_id = "" || String.trim evidence_fingerprint = ""
  then Error Invalid_identity
  else Ok { source = Approval_evidence approval_id; evidence_fingerprint }

let answered_ask_identity ~ask_id ~evidence_fingerprint =
  if String.trim ask_id = "" || String.trim evidence_fingerprint = ""
  then Error Invalid_identity
  else Ok { source = Answered_ask ask_id; evidence_fingerprint }

let source_field = function
  | Approval_evidence id -> "approval_id", `String id
  | Answered_ask id -> "ask_id", `String id

type admission =
  | Admission_new of Agent_core.Checkpoint.t
  | Admission_resume of Agent_core.Checkpoint.t

let marker_key = "masc.approval_input_admission"

let digest message =
  Keeper_context_core_message_json.message_to_json message
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex

let marker_values (message : Agent_core.Types.message) =
  List.filter_map
    (fun (key, value) -> if String.equal key marker_key then Some value else None)
    message.metadata

let without_marker (message : Agent_core.Types.message) =
  { message with metadata =
      List.filter (fun (key, _) -> not (String.equal key marker_key)) message.metadata }

let decode_marker = function
  | `Assoc fields when List.length fields = 4 ->
    let one key =
      match List.filter (fun (name, _) -> String.equal name key) fields with
      | [ (_, value) ] -> Some value
      | _ -> None
    in
    (match one "version", (match one "approval_id", one "ask_id" with
      | Some (`String id), None -> Some (Approval_evidence id)
      | None, Some (`String id) -> Some (Answered_ask id)
      | _ -> None), one "evidence_fingerprint", one "message_sha256" with
     | Some (`Int 1), Some source, Some (`String evidence_fingerprint),
       Some (`String body_digest) ->
       (match (match source with
                | Approval_evidence approval_id -> identity ~approval_id ~evidence_fingerprint
                | Answered_ask ask_id -> answered_ask_identity ~ask_id ~evidence_fingerprint),
              Digestif.SHA256.consistent_of_hex_opt body_digest with
        | Ok identity, Some hash when String.equal body_digest (Digestif.SHA256.to_hex hash) ->
          Ok (identity, body_digest)
        | _ -> Error Malformed_marker)
     | _ -> Error Malformed_marker)
  | _ -> Error Malformed_marker

let contains ~identity:expected ~message messages =
  let expected_digest = digest message in
  List.exists
    (fun current ->
      match marker_values current with
      | [ marker ] ->
        (match decode_marker marker with
         | Ok (actual, body_digest) ->
           current.Agent_core.Types.role = Agent_core.Types.User
           && actual.source = expected.source
           && String.equal actual.evidence_fingerprint expected.evidence_fingerprint
           && String.equal body_digest expected_digest
           && String.equal body_digest (digest (without_marker current))
         | Error _ -> false)
      | _ -> false)
    messages

let prepare ~identity:expected ~message (checkpoint : Agent_core.Checkpoint.t) =
  if message.Agent_core.Types.role <> Agent_core.Types.User || marker_values message <> []
  then Error Invalid_input
  else
    let expected_digest = digest message in
    let rec inspect found kept = function
      | [] -> Ok (found, List.rev kept)
      | current :: rest ->
        (match marker_values current with
         | [] -> inspect found (current :: kept) rest
         | [ marker ] ->
           (match decode_marker marker with
            | Error _ as error -> error
            | Ok (actual, body_digest) ->
              if not (actual.source = expected.source)
              then inspect found (current :: kept) rest
              else if not (String.equal actual.evidence_fingerprint expected.evidence_fingerprint)
              then Error Conflicting_evidence
              else if current.Agent_core.Types.role <> Agent_core.Types.User
                      || not (String.equal body_digest (digest (without_marker current)))
                      || not (String.equal body_digest expected_digest)
              then
                (* Compaction may rewrite the evidence message while retaining
                   metadata. Preserve that history, revoke its stale marker,
                   and admit the original input again if no intact copy exists. *)
                inspect found (without_marker current :: kept) rest
              else if found then Error Duplicate_admission
              else inspect true (current :: kept) rest)
         | _ -> Error Malformed_marker)
    in
    match inspect false [] checkpoint.messages with
    | Error _ as error -> error
    | Ok (true, messages) ->
      Ok (Admission_resume
            (if messages = checkpoint.messages then checkpoint
             else { checkpoint with messages }))
    | Ok (false, messages) ->
      let marker = `Assoc
        [ "version", `Int 1
        ; source_field expected.source
        ; "evidence_fingerprint", `String expected.evidence_fingerprint
        ; "message_sha256", `String expected_digest
        ]
      in
      let admitted = { message with metadata = message.metadata @ [ marker_key, marker ] } in
      Ok (Admission_new { checkpoint with messages = messages @ [ admitted ] })
