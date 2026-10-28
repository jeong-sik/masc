module Job_id = struct
  type t = string
  let fresh = Random_id.uuid_v7
  let of_string = Random_id.parse_uuid_v7
  let to_string value = value
end

type source =
  { task_id : string option
  ; turn_ref : Ids.Turn_ref.t option
  ; tool_use_id : string option
  ; trace_id : string option
  ; keeper_turn_id : int option
  }

open Result.Syntax
let nullable_json encode = function None -> `Null | Some value -> encode value

let source_to_json source =
  `Assoc
    [ "task_id", nullable_json (fun value -> `String value) source.task_id
    ; "turn_ref", nullable_json (fun value -> `String (Ids.Turn_ref.to_string value)) source.turn_ref
    ; "tool_use_id", nullable_json (fun value -> `String value) source.tool_use_id
    ; "trace_id", nullable_json (fun value -> `String value) source.trace_id
    ; "keeper_turn_id", nullable_json (fun value -> `Int value) source.keeper_turn_id ]

let string = function
  | `String value when value <> "" -> Ok value
  | _ -> Error "expected nonempty source string"
let integer = function `Int value -> Ok value | _ -> Error "expected source integer"
let nullable decode = function `Null -> Ok None | value -> Result.map Option.some (decode value)
let source_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)
      = ["keeper_turn_id";"task_id";"tool_use_id";"trace_id";"turn_ref"] ->
      let field key decode = match List.assoc_opt key fields with
        | Some value -> decode value | None -> Error ("missing source " ^ key) in
      let* task_id = field "task_id" (nullable string) in
      let* turn_ref = field "turn_ref" (nullable (fun value ->
        let* value = string value in
        match Ids.Turn_ref.of_string value with Some value -> Ok value
        | None -> Error "invalid source turn reference")) in
      let* tool_use_id = field "tool_use_id" (nullable string) in
      let* trace_id = field "trace_id" (nullable string) in
      let* keeper_turn_id = field "keeper_turn_id" (nullable integer) in
      Ok {task_id;turn_ref;tool_use_id;trace_id;keeper_turn_id}
  | _ -> Error "source has missing, duplicate or unknown fields"
