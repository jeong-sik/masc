let ( let* ) = Result.bind
type state = Queued | Running | Confirmed | Failed_before_effect | Outcome_unknown
type receipt = {
  instance_id : string; incarnation : string; request_id : string; requester : string;
  executor : string option; input_sha256 : string; action : Yojson.Safe.t;
  state : state; result : Yojson.Safe.t option; detail : string option;
}
type package_status = Package_confirmed | Package_failed_before_effect | Package_outcome_unknown
type package_result = { status : package_status; result : Yojson.Safe.t; output : Lane_addon_types.output }
let state_name = function Queued -> "queued" | Running -> "running" | Confirmed -> "confirmed"
  | Failed_before_effect -> "failed_before_effect" | Outcome_unknown -> "outcome_unknown"
let optional f = Option.fold ~none:`Null ~some:f
let to_json (r : receipt) = `Assoc ["instance_id", `String r.instance_id;
  "incarnation", `String r.incarnation; "request_id", `String r.request_id;
  "requester", `String r.requester; "executor", optional (fun value -> `String value) r.executor;
  "input_sha256", `String r.input_sha256; "action", r.action;
  "state", `String (state_name r.state); "result", optional Fun.id r.result;
  "detail", optional (fun value -> `String value) r.detail]
let text fields key = match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | _ -> Error ("missing non-blank " ^ key)
let object_ = function `Assoc fields -> Ok fields | _ -> Error "expected an object"
let unique fields =
  let names = List.map fst fields in
  if List.length names = List.length (List.sort_uniq String.compare names) then Ok ()
  else Error "duplicate object member"
let exact names json = let* fields = object_ json in
  if List.sort String.compare (List.map fst fields) = List.sort String.compare names then Ok fields
  else Error ("expected exactly fields: " ^ String.concat ", " names)
let traverse f values = List.fold_left (fun acc value ->
  let* acc = acc in let* value = f value in Ok (value :: acc)) (Ok []) values |> Result.map List.rev
let rec canonical = function
  | `Assoc fields -> let* () = unique fields in
      let* fields = traverse (fun (key, value) -> let* value = canonical value in Ok (key, value)) fields in
      Ok (`Assoc (List.sort (fun (a, _) (b, _) -> String.compare a b) fields))
  | `List values -> traverse canonical values |> Result.map (fun values -> `List values)
  | `Float value when not (Float.is_finite value) -> Error "non-finite JSON number"
  | `Float value when Float.is_integer value ->
      (* JSON encodings 1 and 1.0 identify the same normalized request. The
         decimal serializer also handles values beyond native integer range. *)
      let encoded = Printf.sprintf "%.0f" value in
      (try Ok (Yojson.Safe.from_string encoded) with Yojson.Json_error message -> Error message)
  | `Intlit value ->
      (try match Yojson.Safe.from_string value with
        | (`Int _ | `Intlit _) as value -> Ok value
        | _ -> Error "invalid JSON integer"
       with Yojson.Json_error message -> Error message)
  | (`Null | `Bool _ | `Int _ | `Float _ | `String _) as value -> Ok value
let input_digest json = Digestif.SHA256.(to_hex (digest_string (Yojson.Safe.to_string json)))
let context instance_id = `Assoc ["instance_id", `String instance_id; "incarnation", `String instance_id]
let arguments ~instance_id ~request_id ~action = `Assoc ["context", context instance_id;
  "request_id", `String request_id; "action", action]
let of_json json =
  let* fields = exact ["instance_id"; "incarnation"; "request_id"; "requester"; "executor";
    "input_sha256"; "action"; "state"; "result"; "detail"] json in
  let* instance_id = text fields "instance_id" in let* incarnation = text fields "incarnation" in
  let* request_id = text fields "request_id" in let* requester = text fields "requester" in
  let* input_sha256 = text fields "input_sha256" in
  let nullable_text name = match List.assoc name fields with `Null -> Ok None
    | _ -> text fields name |> Result.map Option.some in
  let* executor = nullable_text "executor" in let* detail = nullable_text "detail" in
  let* state = match List.assoc "state" fields with
    | `String "queued" -> Ok Queued | `String "running" -> Ok Running
    | `String "confirmed" -> Ok Confirmed | `String "failed_before_effect" -> Ok Failed_before_effect
    | `String "outcome_unknown" -> Ok Outcome_unknown | _ -> Error "invalid action state" in
  let* action = canonical (List.assoc "action" fields) in
  let* result = match List.assoc "result" fields with
    | `Null -> Ok None
    | `Assoc _ as value -> let* value = canonical value in Ok (Some value)
    | _ -> Error "retained action result must be an object or null" in
  let* normalized = canonical (arguments ~instance_id ~request_id ~action) in
  if incarnation <> instance_id || input_digest normalized <> input_sha256
  then Error "retained action identity or input digest mismatch"
  else Ok {instance_id;incarnation;request_id;requester;executor;input_sha256;action;state;result;detail}

(* Restrict advertised schemas to the subset the existing validator can
   enforce. Traverse containers here so nested required/additionalProperties
   and leaf enum/type constraints use the same validation path as host tools. *)
let schema_keys = ["type"; "properties"; "required"; "additionalProperties"; "items";
  "enum"; "const"; "description"; "title"; "minimum"; "maximum";
  "exclusiveMinimum"; "exclusiveMaximum"; "minLength"; "maxLength"; "minItems"; "maxItems"]
let rec schema_node schema =
  let* fields = object_ schema in let* () = unique fields in
  let* () = if List.for_all (fun (key, _) -> List.mem key schema_keys) fields then Ok ()
    else Error "action schema declares an unsupported JSON Schema keyword" in
  let* () = match List.assoc_opt "enum" fields with
    | None | Some (`List _) -> Ok () | Some _ -> Error "schema enum must be an array" in
  let* kind = text fields "type" in
  match kind with
  | "object" ->
      let* properties = match List.assoc_opt "properties" fields with
        | Some (`Assoc values) -> let* () = unique values in Ok values
        | _ -> Error "action object schema requires properties" in
      let* () = match List.assoc_opt "additionalProperties" fields with
        | Some (`Bool false) -> Ok () | _ -> Error "action object schema requires additionalProperties=false" in
      let* () = match List.assoc_opt "required" fields with
        | None -> Ok ()
        | Some (`List values) -> let* names = traverse (function
            | `String name when List.mem_assoc name properties -> Ok name
            | _ -> Error "schema required must name declared properties") values in
            if List.length names = List.length (List.sort_uniq String.compare names) then Ok ()
            else Error "duplicate schema required member"
        | _ -> Error "schema required must be an array" in
      let* _ = traverse (fun (_, schema) -> schema_node schema) properties in Ok ()
  | "array" -> (match List.assoc_opt "items" fields with
      | Some schema -> schema_node schema | None -> Error "action array schema requires items")
  | "string" | "integer" | "number" | "boolean" -> Ok ()
  | _ -> Error "unsupported action schema type"
let validate_schema schema =
  let* _ = canonical schema in
  let* () = schema_node schema in
  let shape = Tool_input_validation.schema_shape schema in
  if shape.errors <> [] then Error (String.concat "; " shape.errors)
  else if List.sort String.compare shape.properties <> ["action"; "context"; "request_id"]
       || List.sort String.compare shape.required <> ["action"; "context"; "request_id"]
  then Error "action tool schema must require exactly context, request_id and action"
  else
    let* fields = object_ schema in
    let* properties = match List.assoc_opt "properties" fields with
      | Some (`Assoc fields) -> Ok fields | _ -> Error "missing action tool properties" in
    let kind name = match List.assoc_opt name properties with
      | Some (`Assoc fields) -> List.assoc_opt "type" fields | _ -> None in
    if kind "context" <> Some (`String "object") || kind "request_id" <> Some (`String "string")
       || kind "action" <> Some (`String "object")
    then Error "action tool requires object context, string request_id and object action"
    else let context = List.assoc "context" properties in
      let shape = Tool_input_validation.schema_shape context in
      if List.sort String.compare shape.properties <> ["incarnation"; "instance_id"]
         || List.sort String.compare shape.required <> ["incarnation"; "instance_id"]
      then Error "action context must require exactly instance_id and incarnation"
      else Ok ()
let rec validate_node ~name schema value =
  (* The outer value property preserves this node's type/enum/range contract,
     including scalar and array nodes. It avoids synthetic string matching. *)
  let wrapper = `Assoc ["type", `String "object"; "properties", `Assoc ["value", schema];
    "required", `List [`String "value"]; "additionalProperties", `Bool false] in
  let* _ = Tool_input_validation.validate_args ~schema:wrapper ~name
    ~args:(`Assoc ["value", value]) () |> Result.map_error Tool_result.message in
  (* Agent core retains const and enum in its authoritative schema; the host
     middleware's parameter projection does not retain every nested keyword. *)
  let* schema_view = Agent_core.Types.tool_schema_of_input_schema ~name ~description:"Lane action"
    ~input_schema:wrapper () in
  let* () = match Agent_core.Tool_input_validation.validate schema_view (`Assoc ["value", value]) with
    | Agent_core.Tool_input_validation.Valid _ -> Ok ()
    | Agent_core.Tool_input_validation.Invalid errors ->
        Error (Agent_core.Tool_input_validation.format_errors ~tool_name:name errors) in
  let* fields = object_ schema in
  match value with
  | `Assoc values ->
      let* _ = Tool_input_validation.validate_args ~schema ~name ~args:value ()
        |> Result.map_error Tool_result.message in
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc properties) ->
           let* _ = traverse (fun (key, value) -> match List.assoc_opt key properties with
             | Some schema -> validate_node ~name schema value
             | None -> Error ("unknown action field: " ^ key)) values in Ok ()
       | _ -> Error "object action requires declared properties")
  | `List values -> (match List.assoc_opt "items" fields with
      | Some schema -> let* _ = traverse (validate_node ~name schema) values in Ok ()
      | None -> Error "array action requires declared items")
  | _ -> Ok ()
let validate ~schema ~name input =
  let* () = validate_schema schema in
  let* input = canonical input in
  let* () = validate_node ~name schema input in Ok input
let decode_result ~store ~max_bytes json =
  let* fields = exact ["status"; "result"; "output"] json in
  let* status = match List.assoc "status" fields with
    | `String "confirmed" -> Ok Package_confirmed
    | `String "failed_before_effect" -> Ok Package_failed_before_effect
    | `String "outcome_unknown" -> Ok Package_outcome_unknown
    | _ -> Error "action result requires an explicit package outcome" in
  let* result = match List.assoc "result" fields with
    | `Assoc _ as value -> canonical value
    | _ -> Error "package action result must be an object" in
  let* output = Lane_addon_packet.decode ~store ~max_bytes (List.assoc "output" fields) in
  Ok {status; result; output}
