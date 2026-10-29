type snapshot = { version : int; shared : bool }
type request =
  { operation_id : string; expected_version : int; requested : bool
  ; expected_artifact_revision : int; expected_artifact_sha256 : string }
type outcome = Applied of snapshot | Conflict of snapshot
type receipt = { request : request; outcome : outcome; publication_matches : bool }
type t = { id : string; snapshot : snapshot; latest : receipt option }

type error = Invalid of string | Operation_reused
type transition = Recorded of t * receipt | Replay of receipt

let ( let* ) = Result.bind
let max_safe_integer = 9_007_199_254_740_991L
let valid_version value = value >= 0 && Int64.of_int value <= max_safe_integer

let valid_operation_id value =
  match Random_id.parse_uuid_v7 value with
  | Ok canonical -> String.equal value canonical
  | Error _ -> false

let valid_sha256 value =
  String.length value = 64 && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) value

let initial ~id ~shared =
  if not (Published_artifact.valid_id id) then Error (Invalid "invalid artifact id")
  else Ok { id; snapshot = { version = 0; shared }; latest = None }

let id state = state.id
let snapshot state = state.snapshot
let latest state = state.latest

let valid_request request =
  valid_operation_id request.operation_id && valid_version request.expected_version
  && valid_version request.expected_artifact_revision && request.expected_artifact_revision > 0
  && valid_sha256 request.expected_artifact_sha256

let receipt_snapshot receipt = match receipt.outcome with
  | Applied snapshot | Conflict snapshot -> snapshot

let valid_receipt receipt =
  let request = receipt.request in
  let snapshot = receipt_snapshot receipt in
  valid_request request && valid_version snapshot.version &&
  match receipt.outcome with
  | Applied _ ->
    receipt.publication_matches && Int64.of_int request.expected_version < max_safe_integer &&
    snapshot.version = request.expected_version + 1 && snapshot.shared = request.requested
  | Conflict _ -> snapshot.version <> request.expected_version || not receipt.publication_matches

let apply state ~publication_matches request =
  if not (valid_request request) then Error (Invalid "invalid share request")
  else match state.latest with
    | Some receipt when receipt.request = request -> Ok (Replay receipt)
    | Some receipt when String.equal receipt.request.operation_id request.operation_id -> Error Operation_reused
    | Some _ | None ->
      let previous = state.snapshot in
      if publication_matches && request.expected_version = previous.version && Int64.of_int previous.version = max_safe_integer
      then Error (Invalid "share version exhausted")
      else
        let outcome, snapshot =
          if request.expected_version <> previous.version || not publication_matches then Conflict previous, previous
          else
            let next = { version = previous.version + 1; shared = request.requested } in
            Applied next, next in
        let receipt = { request; outcome; publication_matches } in
        Ok (Recorded ({ state with snapshot; latest = Some receipt }, receipt))

let snapshot_to_json snapshot =
  `Assoc ["version", `Int snapshot.version; "shared", `Bool snapshot.shared]

let receipt_to_json receipt =
  let kind, snapshot = match receipt.outcome with
    | Applied snapshot -> "applied", snapshot
    | Conflict snapshot -> "conflict", snapshot in
  `Assoc ["operation_id", `String receipt.request.operation_id;
          "expected_version", `Int receipt.request.expected_version;
          "expected_artifact_revision", `Int receipt.request.expected_artifact_revision;
          "expected_artifact_sha256", `String receipt.request.expected_artifact_sha256;
          "requested", `Bool receipt.request.requested;
          "publication_matches", `Bool receipt.publication_matches;
          "outcome", `String kind; "snapshot", snapshot_to_json snapshot]

let to_json state =
  `Assoc ["schema", `String "masc.published_artifact_share.v3";
          "id", `String state.id; "snapshot", snapshot_to_json state.snapshot;
          "latest", Option.fold ~none:`Null ~some:receipt_to_json state.latest]

let fields names = function
  | `Assoc values when List.sort String.compare (List.map fst values) = List.sort String.compare names -> Ok values
  | _ -> Error (Invalid "invalid or duplicate share fields")

let string name values = match List.assoc name values with
  | `String value -> Ok value
  | _ -> Error (Invalid ("invalid " ^ name))

let boolean name values = match List.assoc name values with
  | `Bool value -> Ok value
  | _ -> Error (Invalid ("invalid " ^ name))

let version name values = match List.assoc name values with
  | `Int value when valid_version value -> Ok value
  | _ -> Error (Invalid ("invalid " ^ name))

let snapshot_of_json json =
  let* values = fields ["version"; "shared"] json in
  let* version = version "version" values in
  let* shared = boolean "shared" values in
  Ok { version; shared }

let receipt_of_json json =
  let* values = fields ["operation_id"; "expected_version"; "expected_artifact_revision"; "expected_artifact_sha256";
    "requested"; "publication_matches"; "outcome"; "snapshot"] json in
  let* operation_id = string "operation_id" values in
  let* expected_version = version "expected_version" values in
  let* expected_artifact_revision = version "expected_artifact_revision" values in
  let* expected_artifact_sha256 = string "expected_artifact_sha256" values in
  let* requested = boolean "requested" values in
  let* publication_matches = boolean "publication_matches" values in
  let* snapshot = snapshot_of_json (List.assoc "snapshot" values) in
  let* outcome = match List.assoc "outcome" values with
    | `String "applied" -> Ok (Applied snapshot)
    | `String "conflict" -> Ok (Conflict snapshot)
    | _ -> Error (Invalid "invalid share outcome") in
  let receipt = { request = { operation_id; expected_version; requested; expected_artifact_revision; expected_artifact_sha256 };
    outcome; publication_matches } in
  if valid_receipt receipt then Ok receipt else Error (Invalid "invalid share receipt")

let of_json = function
  | `Assoc values when List.sort String.compare (List.map fst values) = ["id"; "shared"] ->
    let* id = string "id" values in
    let* shared = boolean "shared" values in
    initial ~id ~shared
  | json ->
    let* values = fields ["schema"; "id"; "snapshot"; "latest"] json in
    let* () = match List.assoc "schema" values with
      | `String "masc.published_artifact_share.v3" -> Ok ()
      | _ -> Error (Invalid "invalid share schema") in
    let* id = string "id" values in
    let* snapshot = snapshot_of_json (List.assoc "snapshot" values) in
    let* _ = initial ~id ~shared:snapshot.shared in
    let* latest = match List.assoc "latest" values with
      | `Null -> Ok None
      | json -> receipt_of_json json |> Result.map Option.some in
    match latest with
    | None when snapshot.version = 0 -> Ok { id; snapshot; latest }
    | Some receipt when receipt_snapshot receipt = snapshot -> Ok { id; snapshot; latest }
    | Some _ | None -> Error (Invalid "share snapshot does not match its latest receipt")
