module Rules = Keeper_approval_queue_rules_types

type presence = Active | Deleted

type state =
  { revision : string
  ; rule : Rules.approval_rule
  ; presence : presence
  ; operation_id : string
  }

type intent = { expected_revision : string option; next : state }

type outcome = Apply of state | Already_applied of state | Conflict of state option

let rule state = match state.presence with Active -> Some state.rule | Deleted -> None
let revision = Option.map (fun state -> state.revision)

let identity_equal (left : Rules.approval_rule) (right : Rules.approval_rule) =
  String.equal left.keeper_name right.keeper_name
  && String.equal left.tool_name right.tool_name
  && String.equal left.request_fingerprint right.request_fingerprint

let same_rule left right =
  Yojson.Safe.equal (Rules.approval_rule_to_yojson left)
    (Rules.approval_rule_to_yojson right)

let valid_token value = String.trim value <> ""
let option_exists f = function None -> false | Some value -> f value

let prepare ~current ~revision:new_revision ~operation_id ~presence rule =
  if not (valid_token new_revision && valid_token operation_id) then
    Error "rule revision and operation ID must be nonempty"
  else if option_exists (fun state ->
    String.equal state.revision new_revision) current then
    Error "rule mutation must allocate a fresh revision"
  else if option_exists (fun state -> String.equal state.operation_id operation_id) current then
    Error "replay the stored intent instead of reusing an operation ID"
  else if option_exists (fun state -> not (identity_equal state.rule rule)) current then
    Error "rule mutation identity does not match current state"
  else
    match presence, current with
    | Deleted, None -> Error "cannot delete an absent rule"
    | Deleted, Some { presence = Deleted; _ } -> Error "rule is already deleted"
    | Deleted, Some state when not (same_rule state.rule rule) ->
        Error "deletion must retain the exact current rule"
    | Active, _ | Deleted, Some _ ->
        Ok { expected_revision = revision current;
             next = { revision = new_revision; operation_id; presence; rule } }

let same_state left right =
  String.equal left.revision right.revision
  && String.equal left.operation_id right.operation_id
  && left.presence = right.presence && same_rule left.rule right.rule

let decide ~current intent =
  match current with
  | Some state when same_state state intent.next -> Already_applied state
  | Some state when String.equal state.operation_id intent.next.operation_id -> Conflict current
  | Some state when not (identity_equal state.rule intent.next.rule) -> Conflict current
  | Some state when intent.next.presence = Deleted
      && (state.presence = Deleted || not (same_rule state.rule intent.next.rule)) -> Conflict current
  | _ ->
      if Option.equal String.equal (revision current) intent.expected_revision
      then Apply intent.next
      else Conflict current

let state_to_yojson state =
  `Assoc [ "revision", `String state.revision;
           "operation_id", `String state.operation_id;
           "presence", `String (match state.presence with Active -> "active" | Deleted -> "deleted");
           "rule", Rules.approval_rule_to_yojson state.rule ]

let ( let* ) = Result.bind

let fields_exact names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)
      = List.sort String.compare names -> Ok fields
  | _ -> Error "unexpected rule revision fields"

let token = function
  | `String value when valid_token value -> Ok value
  | _ -> Error "rule revision token must be a nonempty string"

let state_of_yojson json =
  let* fields = fields_exact [ "revision"; "operation_id"; "presence"; "rule" ] json in
  let* revision = token (List.assoc "revision" fields) in
  let* operation_id = token (List.assoc "operation_id" fields) in
  let* presence = match List.assoc "presence" fields with
    | `String "active" -> Ok Active
    | `String "deleted" -> Ok Deleted
    | _ -> Error "unknown rule presence" in
  let* rule = Rules.approval_rule_of_yojson_with_error (List.assoc "rule" fields) in
  Ok { revision; operation_id; presence; rule }

let intent_to_yojson intent =
  `Assoc [ "expected_revision", (match intent.expected_revision with
      | None -> `Null | Some value -> `String value);
    "next", state_to_yojson intent.next ]

let intent_of_yojson json =
  let* fields = fields_exact [ "expected_revision"; "next" ] json in
  let* expected_revision = match List.assoc "expected_revision" fields with
    | `Null -> Ok None
    | value -> Result.map Option.some (token value) in
  let* next = state_of_yojson (List.assoc "next" fields) in
  if Option.equal String.equal expected_revision (Some next.revision) then
    Error "rule mutation reuses its expected revision"
  else match next.presence, expected_revision with
    | Deleted, None -> Error "deletion requires an existing revision"
    | Active, _ | Deleted, Some _ -> Ok { expected_revision; next }
