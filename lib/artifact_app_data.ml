type target = { artifact_id : string; revision : int }
type request = { target : target; id : string; expected_version : int; data : Yojson.Safe.t }
type receipt = { id : string; expected_version : int; data_sha256 : string; at : string }
type t = { target : target; actor : string; version : int; data : Yojson.Safe.t; receipts : receipt list }
type error = Invalid of string | Conflict | Request_collision
module Ids = Set.Make (String)
open Result.Syntax
let safe_integer n = n >= 0 && Int64.of_int n <= 9_007_199_254_740_991L
let text value = String.trim value <> "" && String.is_valid_utf_8 value
let fields allowed = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare allowed -> Ok fields
  | _ -> Error "missing, duplicate or unknown application data field"
let field name fields = List.assoc name fields
let string name fields = match field name fields with
  | `String value when text value -> Ok value
  | _ -> Error ("invalid " ^ name)
let integer ~minimum name fields = match field name fields with
  | `Int value when value >= minimum && safe_integer value -> Ok value
  | _ -> Error ("invalid " ^ name)
let uuid id = let* canonical = Random_id.parse_uuid_v7 id in
  if id = canonical then Ok id else Error "noncanonical application request id"
let rec json_value = function
  | (`Null | `Bool _) as value -> Ok value
  | `Int n as value when Int64.of_int n >= -9_007_199_254_740_991L && Int64.of_int n <= 9_007_199_254_740_991L -> Ok value
  | `Float f as value when Float.is_finite f -> Ok value
  | `String s as value when String.is_valid_utf_8 s -> Ok value
  | `List values -> let* values = json_values values in Ok (`List values)
  | `Assoc values ->
    let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) values in
    let rec collect previous = function
      | [] -> Ok []
      | (name, value) :: rest ->
        if not (String.is_valid_utf_8 name) || previous = Some name then Error "invalid or duplicate application data key"
        else let* value = json_value value in let* rest = collect (Some name) rest in Ok ((name, value) :: rest) in
    let* values = collect None sorted in Ok (`Assoc values)
  | _ -> Error "application data must contain finite interoperable JSON values"
and json_values = function
  | [] -> Ok []
  | value :: rest -> let* value = json_value value in let* rest = json_values rest in Ok (value :: rest)
let data_of_json = function
  | `Assoc _ as json -> json_value json
  | _ -> Error "application data must be a JSON object"
let digest data = Agent_core_sha256.(to_hex (digest_string (Yojson.Safe.to_string data)))
let valid_target target =
  if Published_artifact.valid_id target.artifact_id && target.revision > 0 && safe_integer target.revision then Ok ()
  else Error "invalid application data artifact or revision"
let target_to_json target = `Assoc ["artifact_id", `String target.artifact_id; "revision", `Int target.revision]
let target_of_json json =
  let* fields = fields ["artifact_id"; "revision"] json in
  let* artifact_id = string "artifact_id" fields in let* revision = integer ~minimum:1 "revision" fields in
  let target = { artifact_id; revision } in let* () = valid_target target in Ok target
let request_of_json json =
  let* fields = fields ["target"; "id"; "expected_version"; "data"] json in
  let* target = target_of_json (field "target" fields) in
  let* id = string "id" fields in let* id = uuid id in
  let* expected_version = integer ~minimum:0 "expected_version" fields in
  let* data = data_of_json (field "data" fields) in Ok { target; id; expected_version; data }
let empty ~target ~actor =
  let* () = valid_target target in
  if not (text actor) then Error "invalid application data actor"
  else Ok { target; actor; version = 0; data = `Assoc []; receipts = [] }
let apply state ~at (request : request) =
  if request.target <> state.target || not (text at) then Error (Invalid "application data target or timestamp mismatch")
  else let data_sha256 = digest request.data in
    match List.find_opt (fun (receipt : receipt) -> receipt.id = request.id) state.receipts with
    | Some receipt when receipt.expected_version = request.expected_version && receipt.data_sha256 = data_sha256 -> Ok state
    | Some _ -> Error Request_collision
    | None when request.expected_version <> state.version -> Error Conflict
    | None when not (safe_integer (state.version + 1)) -> Error (Invalid "application data version exhausted")
    | None ->
      let receipt = { id = request.id; expected_version = request.expected_version; data_sha256; at } in
      Ok { state with version = state.version + 1; data = request.data; receipts = state.receipts @ [receipt] }
let receipt_to_json (receipt : receipt) = `Assoc
  ["id", `String receipt.id; "expected_version", `Int receipt.expected_version;
   "data_sha256", `String receipt.data_sha256; "at", `String receipt.at]
let receipt_of_json json =
  let* fields = fields ["id"; "expected_version"; "data_sha256"; "at"] json in
  let* id = string "id" fields in let* id = uuid id in
  let* expected_version = integer ~minimum:0 "expected_version" fields in
  let* data_sha256 = string "data_sha256" fields in
  let* () = Tool_blob_store.validate_sha256 data_sha256 |> Result.map_error (fun _ -> "invalid application data digest") in
  let* at = string "at" fields in Ok { id; expected_version; data_sha256; at }
let to_json state = `Assoc
  ["schema", `String "masc.artifact_app_data.v1"; "target", target_to_json state.target;
   "actor", `String state.actor; "version", `Int state.version; "data", state.data;
   "receipts", `List (List.map receipt_to_json state.receipts)]
let of_json json =
  let* fields = fields ["schema"; "target"; "actor"; "version"; "data"; "receipts"] json in
  let* () = if field "schema" fields = `String "masc.artifact_app_data.v1" then Ok () else Error "invalid application data schema" in
  let* target = target_of_json (field "target" fields) in let* actor = string "actor" fields in
  let* version = integer ~minimum:0 "version" fields in let* data = data_of_json (field "data" fields) in
  let rec receipts sequence ids = function
    | [] -> Ok []
    | json :: rest ->
      let* receipt = receipt_of_json json in
      if receipt.expected_version <> sequence || Ids.mem receipt.id ids then Error "invalid application data receipt history"
      else let* rest = receipts (sequence + 1) (Ids.add receipt.id ids) rest in Ok (receipt :: rest) in
  let* receipts = match field "receipts" fields with
    | `List values -> receipts 0 Ids.empty values | _ -> Error "invalid application data receipts" in
  let* () = if List.length receipts <> version then Error "application data version does not match receipts"
    else match List.rev receipts with
      | [] when data = `Assoc [] -> Ok ()
      | receipt :: _ when receipt.data_sha256 = digest data -> Ok ()
      | _ -> Error "application data does not match its receipt" in
  Ok { target; actor; version; data; receipts }
