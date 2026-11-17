module Fingerprint = Keeper_approval_request_fingerprint
let ( let* ) = Result.bind

type intent =
  { request_id : string
  ; request_digest : string
  ; request : Fingerprint.exact_request
  ; digest : string
  ; json : Yojson.Safe.t
  }
type wait =
  { bound_intent_digest : string
  ; approval_id : string
  ; input_hash : string
  ; json : Yojson.Safe.t
  }

let intent_schema = "lane.addon.request-approval-intent.v1"
let wait_schema = "lane.addon.request-approval-wait.v1"

let identity label value =
  if String.trim value = "" || String.contains value '\000'
  then Error (label ^ " must be nonblank text without NUL") else Ok ()

let sha256 label value =
  if String_util.is_lowercase_sha256_hex value then Ok ()
  else Error (label ^ " must be a lowercase SHA-256")

let intent ~request_id ~request_digest ~request =
  let* () = identity "original request_id" request_id in
  let* () = sha256 "original request_digest" request_digest in
  let fields =
    ["schema", `String intent_schema; "original_request_id", `String request_id;
     "original_request_digest", `String request_digest;
     "exact_request", Fingerprint.exact_request_to_json request] in
  let* capture = Lane_addon_json.canonical (`Assoc fields) in
  let digest = Fingerprint.request_fingerprint capture in
  let* json = Lane_addon_json.canonical (`Assoc (("intent_digest", `String digest) :: fields)) in
  Ok {request_id; request_digest; request; digest; json}

let original_request_id (intent : intent) = intent.request_id
let original_request_digest (intent : intent) = intent.request_digest
let request (intent : intent) = intent.request
let intent_digest (intent : intent) = intent.digest
let intent_to_json (intent : intent) = intent.json
let equal_intent (left : intent) (right : intent) = Yojson.Safe.equal left.json right.json

let fields label keys = function
  | `Assoc values ->
    let* () = Json_util.reject_unknown_fields ~surface:label ~allowed:keys values in
    if List.length keys = List.length values then Ok values else Error (label ^ " has missing fields")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error (label ^ " must be an object")

let text values key =
  let* value = Json_util.require_field_string ~surface:"request approval" key values in
  let* () = identity key value in
  Ok value

let intent_of_json json =
  let* json = Lane_addon_json.canonical json in
  let* values = fields intent_schema
    ["schema"; "original_request_id"; "original_request_digest"; "exact_request"; "intent_digest"] json in
  let* schema = text values "schema" in
  let* () = if String.equal schema intent_schema then Ok () else Error "unknown approval intent schema" in
  let* request_id = text values "original_request_id" in
  let* request_digest = text values "original_request_digest" in
  let* request = Fingerprint.exact_request_of_json (List.assoc "exact_request" values) in
  let* recorded_digest = text values "intent_digest" in
  let* () = sha256 "intent_digest" recorded_digest in
  let* value = intent ~request_id ~request_digest ~request in
  if String.equal value.digest recorded_digest && Yojson.Safe.equal value.json json then Ok value
  else Error "approval intent digest or canonical capture mismatch"

let make_wait ~intent_digest ~approval_id ~input_hash =
  let* () = sha256 "intent_digest" intent_digest in
  let* () = identity "approval_id" approval_id in
  let* () = sha256 "input_hash" input_hash in
  let* json = Lane_addon_json.canonical (`Assoc
    ["schema", `String wait_schema; "intent_digest", `String intent_digest;
     "approval_id", `String approval_id; "input_hash", `String input_hash]) in
  Ok {bound_intent_digest=intent_digest; approval_id; input_hash; json}

let wait (intent : intent) ~approval_id ~input_hash =
  if String.equal input_hash (Fingerprint.input_hash intent.request)
  then make_wait ~intent_digest:intent.digest ~approval_id ~input_hash
  else Error "approval wait input hash differs from its exact intent"

let approval_id (wait : wait) = wait.approval_id
let wait_input_hash (wait : wait) = wait.input_hash
let wait_intent_digest (wait : wait) = wait.bound_intent_digest
let wait_to_json (wait : wait) = wait.json
let equal_wait (left : wait) (right : wait) = Yojson.Safe.equal left.json right.json
let wait_matches_intent (intent : intent) (wait : wait) =
  String.equal wait.bound_intent_digest intent.digest
  && String.equal wait.input_hash (Fingerprint.input_hash intent.request)

let wait_of_json json =
  let* json = Lane_addon_json.canonical json in
  let* values = fields wait_schema ["schema"; "intent_digest"; "approval_id"; "input_hash"] json in
  let* schema = text values "schema" in
  let* () = if String.equal schema wait_schema then Ok () else Error "unknown approval wait schema" in
  let* intent_digest = text values "intent_digest" in
  let* approval_id = text values "approval_id" in
  let* input_hash = text values "input_hash" in
  let* value = make_wait ~intent_digest ~approval_id ~input_hash in
  if Yojson.Safe.equal value.json json then Ok value else Error "approval wait is not canonical"
