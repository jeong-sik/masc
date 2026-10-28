type snapshot = { version : int; shared : bool }
type request = { operation_id : string; expected_version : int; requested : bool }
type outcome = Applied of snapshot | Conflict of snapshot
type receipt = { request : request; outcome : outcome }

module Operations = Map.Make (String)

type t =
  { id : string
  ; initial_shared : bool
  ; snapshot : snapshot
  ; receipts_rev : receipt list
  ; operations : receipt Operations.t
  }

type error = Invalid of string | Operation_reused
type transition = Recorded of t * receipt | Replay of receipt

let ( let* ) = Result.bind
let max_safe_integer = 9_007_199_254_740_991L
let valid_version value = value >= 0 && Int64.of_int value <= max_safe_integer

let valid_operation_id value =
  match Random_id.parse_uuid_v7 value with
  | Ok canonical -> String.equal value canonical
  | Error _ -> false

let initial ~id ~shared =
  if not (Published_artifact.valid_id id) then Error (Invalid "invalid artifact id")
  else Ok { id; initial_shared = shared; snapshot = { version = 0; shared };
            receipts_rev = []; operations = Operations.empty }

let id state = state.id
let snapshot state = state.snapshot
let receipts state = List.rev state.receipts_rev
let find state ~operation_id = Operations.find_opt operation_id state.operations

let apply state request =
  if not (valid_operation_id request.operation_id) then Error (Invalid "invalid share operation id")
  else if not (valid_version request.expected_version) then Error (Invalid "invalid share version")
  else match find state ~operation_id:request.operation_id with
    | Some receipt when receipt.request = request -> Ok (Replay receipt)
    | Some _ -> Error Operation_reused
    | None ->
      let previous = state.snapshot in
      if request.expected_version = previous.version && Int64.of_int previous.version = max_safe_integer
      then Error (Invalid "share version exhausted")
      else
        let outcome, snapshot =
          if request.expected_version <> previous.version then Conflict previous, previous
          else
            let next = { version = previous.version + 1; shared = request.requested } in
            Applied next, next in
        let receipt = { request; outcome } in
        Ok (Recorded ({ state with snapshot; receipts_rev = receipt :: state.receipts_rev;
          operations = Operations.add request.operation_id receipt state.operations }, receipt))

let snapshot_to_json snapshot =
  `Assoc ["version", `Int snapshot.version; "shared", `Bool snapshot.shared]

let receipt_to_json receipt =
  let kind, snapshot = match receipt.outcome with
    | Applied snapshot -> "applied", snapshot
    | Conflict snapshot -> "conflict", snapshot in
  `Assoc ["operation_id", `String receipt.request.operation_id;
          "expected_version", `Int receipt.request.expected_version;
          "requested", `Bool receipt.request.requested;
          "outcome", `String kind; "snapshot", snapshot_to_json snapshot]

let to_json state =
  `Assoc ["schema", `String "masc.published_artifact_share.v2";
          "id", `String state.id; "initial_shared", `Bool state.initial_shared;
          "snapshot", snapshot_to_json state.snapshot;
          "receipts", `List (List.map receipt_to_json (receipts state))]

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
  let* values = fields ["operation_id"; "expected_version"; "requested"; "outcome"; "snapshot"] json in
  let* operation_id = string "operation_id" values in
  let* expected_version = version "expected_version" values in
  let* requested = boolean "requested" values in
  let* snapshot = snapshot_of_json (List.assoc "snapshot" values) in
  let* outcome = match List.assoc "outcome" values with
    | `String "applied" -> Ok (Applied snapshot)
    | `String "conflict" -> Ok (Conflict snapshot)
    | _ -> Error (Invalid "invalid share outcome") in
  Ok { request = { operation_id; expected_version; requested }; outcome }

let of_json = function
  | `Assoc values when
      List.sort String.compare (List.map fst values) = ["id"; "shared"] ->
    let* id = string "id" values in
    let* shared = boolean "shared" values in
    initial ~id ~shared
  | json ->
    let* values = fields ["schema"; "id"; "initial_shared"; "snapshot"; "receipts"] json in
    let* () = match List.assoc "schema" values with
      | `String "masc.published_artifact_share.v2" -> Ok ()
      | _ -> Error (Invalid "invalid share schema") in
    let* id = string "id" values in
    let* shared = boolean "initial_shared" values in
    let* expected_snapshot = snapshot_of_json (List.assoc "snapshot" values) in
    let* initial = initial ~id ~shared in
    let* stored_receipts = match List.assoc "receipts" values with
      | `List values -> Ok values
      | _ -> Error (Invalid "invalid share receipts") in
    let rec replay state = function
      | [] -> Ok state
      | json :: rest ->
        let* expected = receipt_of_json json in
        let* transition = apply state expected.request in
        (match transition with
         | Recorded (state, actual) when actual = expected -> replay state rest
         | Recorded _ | Replay _ -> Error (Invalid "invalid share receipt history")) in
    let* state = replay initial stored_receipts in
    if state.snapshot = expected_snapshot then Ok state
    else Error (Invalid "share snapshot does not match its receipt history")
