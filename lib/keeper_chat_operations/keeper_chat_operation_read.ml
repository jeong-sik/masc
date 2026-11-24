type absence = { keeper_name : string; operation_id : Keeper_operation_id.t }

let schema = "masc.keeper_chat_operation.error.v1"
let unknown_operation_code = "unknown_operation"
let field = "absent_operation"

let public_error_json ?absence ~code ~message ~incident_id () =
  let fields =
    [ "schema", `String schema; "error", `String code; "message", `String message;
      "incident_id", `String incident_id ]
  in
  match absence with
  | None -> `Assoc fields
  | Some { keeper_name; operation_id } ->
      `Assoc ((field, `Assoc ["keeper_name", `String keeper_name;
        "operation_id", `String (Keeper_operation_id.to_string operation_id)]) :: fields)

let confirms_absence expected json =
  let one key fields =
    match List.filter (fun (name, _) -> String.equal name key) fields with
    | [_, value] -> Some value
    | [] | _ :: _ :: _ -> None in
  let nonblank key fields =
    match one key fields with
    | Some (`String value) -> String.trim value <> ""
    | _ -> false in
  match json with
  | `Assoc fields when one "schema" fields = Some (`String schema)
                      && one "error" fields = Some (`String unknown_operation_code)
                      && nonblank "message" fields && nonblank "incident_id" fields ->
      (match one field fields with
       | Some (`Assoc scope) ->
           one "keeper_name" scope = Some (`String expected.keeper_name)
           && one "operation_id" scope = Some (`String (Keeper_operation_id.to_string expected.operation_id))
       | _ -> false)
  | _ -> false
