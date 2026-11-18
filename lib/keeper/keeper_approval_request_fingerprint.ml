let rec canonical_request_json = function
  | `Assoc fields ->
    fields
    |> List.map (fun (key, value) -> key, canonical_request_json value)
    |> List.stable_sort (fun (left, _) (right, _) -> String.compare left right)
    |> fun canonical -> `Assoc canonical
  | `List items -> `List (List.map canonical_request_json items)
  | other -> other
;;

let request_fingerprint (input : Yojson.Safe.t) =
  let canonical_json = canonical_request_json input |> Yojson.Safe.to_string in
  Agent_core_sha256.(digest_string canonical_json |> to_hex)
;;

let ( let* ) = Result.bind

(* Store canonicalization normalizes JSON numbers. Keep the queue's exact
   scalar encoding inside one checked text value instead of changing its hash. *)
module Exact_input = struct
  type t = { value : Yojson.Safe.t; text : string }

  let validate input =
    Lane_addon_json.canonical input
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun _ -> "exact request input has invalid JSON members or numbers")

  let of_text text =
    let* value =
      try Ok (Yojson.Safe.from_string text)
      with Yojson.Json_error _ -> Error "exact request input_json is invalid JSON"
    in
    let* () = validate value in
    let value = canonical_request_json value in
    let encoded = Yojson.Safe.to_string value in
    if String.equal text encoded then Ok { value; text }
    else Error "exact request input JSON text is not canonical"

  let capture input =
    let* () = validate input in
    canonical_request_json input |> Yojson.Safe.to_string |> of_text

  let of_json = function
    | `String text -> of_text text
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
      Error "exact request input_json must be JSON text"

  let to_json input = `String input.text
  let value input = input.value
  let equal left right = String.equal left.text right.text
end

type exact_request =
  { base_path : string
  ; keeper_name : string
  ; operation : string
  ; input : Exact_input.t
  ; input_hash : string
  ; origin : Keeper_approval_origin.t
  ; task_id : string option
  ; goal_id : string option
  ; continuation_channel : Keeper_continuation_channel.t
  ; json : Yojson.Safe.t
  }

let exact_schema = "keeper.approval-exact-request.v2"
let optional_text = function None -> `Null | Some value -> `String value

let identity label value =
  if String.trim value = "" || String.contains value '\000'
  then Error (label ^ " must be nonblank text without NUL") else Ok ()

let optional_identity label = function
  | None -> Ok ()
  | Some value -> identity label value

let exact_nested ~encode decode json =
  let* value = decode json in
  let* encoded = Lane_addon_json.canonical (encode value) in
  if Yojson.Safe.equal json encoded then Ok value
  else Error "exact request has a noncanonical nested value"

let exact_request ~base_path ~keeper_name ~operation ~input ~origin ~task_id ~goal_id ~continuation_channel =
  let* () = identity "base_path" base_path in
  let* () = if Filename.is_relative base_path then Error "base_path must be absolute" else Ok () in
  let* base_path = Config_dir_resolver.canonical_base_path base_path
    |> Result.map_error Config_dir_resolver.canonical_base_path_error_to_string in
  let* keeper = Keeper_id.Keeper_name.of_string keeper_name in
  let keeper_name = Keeper_id.Keeper_name.to_string keeper in
  let* () = identity "operation" operation in
  let* () = optional_identity "task_id" task_id in
  let* () = optional_identity "goal_id" goal_id in
  let* origin_json = Lane_addon_json.canonical (Keeper_approval_origin.to_yojson origin) in
  let* origin = exact_nested ~encode:Keeper_approval_origin.to_yojson
    Keeper_approval_origin.of_yojson origin_json in
  let* channel_json = Lane_addon_json.canonical
    (Keeper_continuation_channel.to_yojson continuation_channel) in
  let* continuation_channel = exact_nested ~encode:Keeper_continuation_channel.to_yojson
    Keeper_continuation_channel.of_yojson channel_json in
  let* input = Exact_input.capture input in
  let input_hash = request_fingerprint (Exact_input.value input) in
  let* json = Lane_addon_json.canonical (`Assoc
    ["schema", `String exact_schema; "base_path", `String base_path;
     "keeper_name", `String keeper_name; "operation", `String operation;
     "input_json", Exact_input.to_json input; "input_hash", `String input_hash;
     "origin", origin_json;
     "task_id", optional_text task_id; "goal_id", optional_text goal_id;
     "continuation_channel", channel_json]) in
  Ok {base_path; keeper_name; operation; input; input_hash; origin; task_id; goal_id;
      continuation_channel; json}

let base_path (request : exact_request) = request.base_path
let keeper_name (request : exact_request) = request.keeper_name
let operation (request : exact_request) = request.operation
let input (request : exact_request) = Exact_input.value request.input
let input_hash (request : exact_request) = request.input_hash
let origin (request : exact_request) = request.origin
let task_id (request : exact_request) = request.task_id
let goal_id (request : exact_request) = request.goal_id
let continuation_channel (request : exact_request) = request.continuation_channel
let exact_request_to_json (request : exact_request) = request.json
let equal_exact_request left right = Yojson.Safe.equal left.json right.json

let fields label keys = function
  | `Assoc values ->
    let* () = Json_util.reject_unknown_fields ~surface:label ~allowed:keys values in
    if List.length keys = List.length values then Ok values
    else Error (label ^ " has missing fields")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error (label ^ " must be an object")

let text values key =
  let* value = Json_util.require_field_string ~surface:exact_schema key values in
  let* () = identity key value in
  Ok value

let nullable_text values key =
  match List.assoc key values with
  | `Null -> Ok None
  | `String value -> let* () = identity key value in Ok (Some value)
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
    Error (key ^ " must be null or text")

let exact_request_of_json json =
  let* json = Lane_addon_json.canonical json in
  let* values = fields exact_schema
    ["schema"; "base_path"; "keeper_name"; "operation"; "input_json"; "input_hash";
     "origin"; "task_id"; "goal_id"; "continuation_channel"] json in
  let* schema = text values "schema" in
  let* () = if String.equal schema exact_schema then Ok () else Error "unknown exact request schema" in
  let* base_path = text values "base_path" in
  let* keeper_name = text values "keeper_name" in
  let* operation = text values "operation" in
  let* recorded_hash = text values "input_hash" in
  let* () = if String_util.is_lowercase_sha256_hex recorded_hash then Ok ()
    else Error "exact request input_hash must be a lowercase SHA-256" in
  let* origin = exact_nested ~encode:Keeper_approval_origin.to_yojson Keeper_approval_origin.of_yojson
    (List.assoc "origin" values) in
  let* task_id = nullable_text values "task_id" in
  let* goal_id = nullable_text values "goal_id" in
  let* continuation_channel = exact_nested ~encode:Keeper_continuation_channel.to_yojson
    Keeper_continuation_channel.of_yojson (List.assoc "continuation_channel" values) in
  let* input = Exact_input.of_json (List.assoc "input_json" values) in
  let* request = exact_request ~base_path ~keeper_name ~operation
    ~input:(Exact_input.value input) ~origin ~task_id ~goal_id ~continuation_channel in
  if String.equal request.input_hash recorded_hash && Yojson.Safe.equal request.json json
  then Ok request else Error "exact request input hash or canonical identity mismatch"

let matches_entry (request : exact_request) ~base_path ~keeper_name ~operation ~input ~input_hash
    ~origin ~task_id ~goal_id ~continuation_channel =
  String.equal request.base_path base_path
  && String.equal request.keeper_name keeper_name
  && String.equal request.operation operation
  && String.equal request.input_hash input_hash
  && Keeper_approval_origin.same_logical_source request.origin origin
  && request.task_id = task_id
  && request.goal_id = goal_id
  && Yojson.Safe.equal
       (Keeper_continuation_channel.to_yojson request.continuation_channel)
       (Keeper_continuation_channel.to_yojson continuation_channel)
  && (match Exact_input.capture input with
      | Ok input -> Exact_input.equal request.input input
      | Error _ -> false)
