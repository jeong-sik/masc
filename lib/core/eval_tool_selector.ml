type t =
  | Tool_name of string
  | Descriptor_id of string
  | Runtime_handler of string
  | Receipt_label of string * string
  | Eval_tag of string

type call =
  { tool_name : string
  ; route_evidence : Yojson.Safe.t option
  }

let trim_nonempty = String_util.trim_nonempty

let label = function
  | Tool_name value -> "tool_name:" ^ value
  | Descriptor_id value -> "descriptor_id:" ^ value
  | Runtime_handler value -> "runtime_handler:" ^ value
  | Receipt_label (key, value) -> "receipt_label:" ^ key ^ "=" ^ value
  | Eval_tag value -> "eval_tag:" ^ value

let to_yojson selector =
  let kind_value kind value =
    `Assoc [ ("type", `String kind); ("value", `String value) ]
  in
  match selector with
  | Tool_name value -> kind_value "tool_name" value
  | Descriptor_id value -> kind_value "descriptor_id" value
  | Runtime_handler value -> kind_value "runtime_handler" value
  | Eval_tag value -> kind_value "eval_tag" value
  | Receipt_label (key, value) ->
      `Assoc
        [ ("type", `String "receipt_label")
        ; ("key", `String key)
        ; ("value", `String value)
        ]

let string_field json key =
  match Json_util.assoc_member_opt key json with
  | Some (`String value) -> trim_nonempty value
  | _ -> None

let errorf fmt = Printf.ksprintf (fun msg -> Error msg) fmt

(* The accepted spellings are exactly the ones [to_yojson] writes. *)
let of_kind_value ~kind ~value =
  match String.lowercase_ascii (String.trim kind), trim_nonempty value with
  | _, None -> errorf "tool selector %S has empty value" kind
  | "tool_name", Some value -> Ok (Tool_name value)
  | "descriptor_id", Some value -> Ok (Descriptor_id value)
  | "runtime_handler", Some value -> Ok (Runtime_handler value)
  | "eval_tag", Some value -> Ok (Eval_tag value)
  | other, Some _ -> errorf "unknown tool selector type: %s" other

(* [to_yojson] writes a ["type"]-tagged object, and that is the only shape
   read back. Every other JSON is a decode error. *)
let of_yojson = function
  | `Assoc _ as json -> (
      match string_field json "type" with
      | Some "receipt_label" -> (
          match string_field json "key", string_field json "value" with
          | Some key, Some value -> Ok (Receipt_label (key, value))
          | _ -> Error "receipt_label selector requires non-empty key and value")
      | Some kind -> (
          match string_field json "value" with
          | Some value -> of_kind_value ~kind ~value
          | None -> errorf "tool selector %S requires non-empty value" kind)
      | None -> Error "tool selector object requires a non-empty \"type\"")
  | other ->
      errorf "tool selector must be an object, got %s" (Json_util.kind_name other)

let route_string_field field route_evidence =
  match route_evidence with
  | Some json -> Json_util.assoc_string_opt field json
  | None -> None

let receipt_label_value key route_evidence =
  match route_evidence with
  | Some json -> (
      match Json_util.assoc_member_opt "receipt_labels" json with
      | Some (`Assoc fields) -> (
          match List.assoc_opt key fields with
          | Some (`String value) -> Some value
          | _ -> None)
      | _ -> None)
  | None -> None

let eval_tags route_evidence =
  match route_evidence with
  | Some json -> Json_util.json_string_list_member "eval_tags" json
  | None -> []

let matches selector call =
  match selector with
  | Tool_name expected -> String.equal call.tool_name expected
  | Descriptor_id expected ->
      Option.equal String.equal
        (Some expected)
        (route_string_field "descriptor_id" call.route_evidence)
  | Runtime_handler expected ->
      Option.equal String.equal
        (Some expected)
        (route_string_field "runtime_handler" call.route_evidence)
  | Receipt_label (key, expected) ->
      Option.equal String.equal
        (Some expected)
        (receipt_label_value key call.route_evidence)
  | Eval_tag expected -> List.exists (String.equal expected) (eval_tags call.route_evidence)

let requires_route_evidence = function
  | Tool_name _ -> false
  | Descriptor_id _ | Runtime_handler _ | Receipt_label _ | Eval_tag _ -> true
