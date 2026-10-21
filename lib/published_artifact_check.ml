type state = Checked | Unchecked
type target = { id : string; revision : int; body_sha256 : string }
type request =
  { target : target; state : state; expected_change_id : string option }
type t =
  { target : target; state : state; change_id : string
  ; changed_by : string; changed_at : string }

let ( let* ) = Result.bind

let fields allowed = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length names <> List.length (List.sort_uniq String.compare names)
    then Error "duplicate fields"
    else if List.exists (fun name -> not (List.mem name allowed)) names
    then Error "unknown field"
    else Ok fields
  | _ -> Error "expected an object"

let required name fields = match List.assoc_opt name fields with
  | Some (`String value) when String.trim value <> "" && String.is_valid_utf_8 value -> Ok value
  | _ -> Error (name ^ " must be a nonblank UTF-8 string")

let change_id value =
  if String.length value = 38 && String.starts_with ~prefix:"check-" value
     && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       (String.sub value 6 32)
  then Ok value else Error "invalid check change id"

let target fields =
  let* id = required "id" fields in
  let* () = if Published_artifact.valid_id id then Ok () else Error "invalid artifact id" in
  let* revision = match List.assoc_opt "revision" fields with
    | Some (`Int n) when n > 0 -> Ok n
    | _ -> Error "revision must be a positive integer" in
  let* body_sha256 = required "body_sha256" fields in
  let* () = match Tool_output.validate_sha256 body_sha256 with
    | Ok () -> Ok ()
    | Error error -> Error (Tool_output.invalid_sha256_to_string error) in
  Ok { id; revision; body_sha256 }

let state fields = match List.assoc_opt "checked" fields with
  | Some (`Bool true) -> Ok Checked
  | Some (`Bool false) -> Ok Unchecked
  | _ -> Error "checked must be a boolean"

let request_of_json json =
  let* fields = fields ["id";"revision";"body_sha256";"checked";"expected_change_id"] json in
  let* target = target fields in
  let* state = state fields in
  let* expected_change_id = match List.assoc_opt "expected_change_id" fields with
    | Some `Null -> Ok None
    | Some (`String value) -> let* value = change_id value in Ok (Some value)
    | None | Some _ -> Error "expected_change_id must be null or a check change id" in
  Ok { target; state; expected_change_id }

let of_json json =
  let* fields = fields
    ["id";"revision";"body_sha256";"checked";"change_id";"changed_by";"changed_at"] json in
  let* target = target fields in
  let* state = state fields in
  let* raw_id = required "change_id" fields in
  let* change_id = change_id raw_id in
  let* changed_by = required "changed_by" fields in
  let* changed_at = required "changed_at" fields in
  let* () = match Time_codec.parse_rfc3339 changed_at with
    | Ok _ -> Ok () | Error Time_codec.Invalid_rfc3339 -> Error "invalid check timestamp" in
  Ok { target; state; change_id; changed_by; changed_at }

let target_fields (target : target) =
  ["id", `String target.id; "revision", `Int target.revision;
   "body_sha256", `String target.body_sha256]

let state_json = function Checked -> `Bool true | Unchecked -> `Bool false

let to_json (check : t) = `Assoc (target_fields check.target @
  ["checked", state_json check.state; "change_id", `String check.change_id;
   "changed_by", `String check.changed_by; "changed_at", `String check.changed_at])

let create ~actor ~at ~change_id (request : request) =
  of_json (`Assoc (target_fields request.target @
    ["checked", state_json request.state; "change_id", `String change_id;
     "changed_by", `String actor; "changed_at", `String at]))

let same_target (a : target) (b : target) =
  String.equal a.id b.id && a.revision = b.revision
  && String.equal a.body_sha256 b.body_sha256
