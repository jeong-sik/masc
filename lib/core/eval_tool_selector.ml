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

let trim_nonempty value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed

let label = function
  | Tool_name value -> "tool_name:" ^ value
  | Descriptor_id value -> "descriptor_id:" ^ value
  | Runtime_handler value -> "runtime_handler:" ^ value
  | Receipt_label (key, value) -> "receipt_label:" ^ key ^ "=" ^ value
  | Eval_tag value -> "eval_tag:" ^ value

let kind_value = function
  | Tool_name value -> ("tool_name", value)
  | Descriptor_id value -> ("descriptor_id", value)
  | Runtime_handler value -> ("runtime_handler", value)
  | Eval_tag value -> ("eval_tag", value)
  | Receipt_label _ -> ("receipt_label", "")

let to_yojson selector =
  match selector with
  | Receipt_label (key, value) ->
      `Assoc
        [ ("type", `String "receipt_label")
        ; ("key", `String key)
        ; ("value", `String value)
        ]
  | (Tool_name _ | Descriptor_id _ | Runtime_handler _ | Eval_tag _) as selector ->
      let kind, value = kind_value selector in
      `Assoc [ ("type", `String kind); ("value", `String value) ]

let string_field json key =
  match Json_util.assoc_member_opt key json with
  | Some (`String value) -> trim_nonempty value
  | _ -> None

let errorf fmt = Printf.ksprintf (fun msg -> Error msg) fmt

let of_kind_value ~kind ~value =
  match String.lowercase_ascii (String.trim kind), trim_nonempty value with
  | _, None -> errorf "tool selector %S has empty value" kind
  | ("tool_name" | "tool" | "name"), Some value -> Ok (Tool_name value)
  | ("descriptor_id" | "descriptor"), Some value -> Ok (Descriptor_id value)
  | ("runtime_handler" | "handler"), Some value -> Ok (Runtime_handler value)
  | ("eval_tag" | "tag"), Some value -> Ok (Eval_tag value)
  | other, Some _ -> errorf "unknown tool selector type: %s" other

let of_yojson = function
  | `String value -> (
      match trim_nonempty value with
      | Some value -> Ok (Tool_name value)
      | None -> Error "tool selector string must be non-empty")
  | `Assoc _ as json -> (
      match string_field json "type", string_field json "kind" with
      | Some "receipt_label", _ | _, Some "receipt_label" -> (
          match string_field json "key", string_field json "value" with
          | Some key, Some value -> Ok (Receipt_label (key, value))
          | _ -> Error "receipt_label selector requires non-empty key and value")
      | Some kind, _ -> (
          match string_field json "value" with
          | Some value -> of_kind_value ~kind ~value
          | None -> errorf "tool selector %S requires non-empty value" kind)
      | None, Some kind -> (
          match string_field json "value" with
          | Some value -> of_kind_value ~kind ~value
          | None -> errorf "tool selector %S requires non-empty value" kind)
      | None, None -> (
          match
            string_field json "tool_name",
            string_field json "descriptor_id",
            string_field json "runtime_handler",
            string_field json "eval_tag"
          with
          | Some value, _, _, _ -> Ok (Tool_name value)
          | _, Some value, _, _ -> Ok (Descriptor_id value)
          | _, _, Some value, _ -> Ok (Runtime_handler value)
          | _, _, _, Some value -> Ok (Eval_tag value)
          | None, None, None, None ->
              Error
                "tool selector object requires type/value or one selector field"))
  | other ->
      errorf "tool selector must be string or object, got %s"
        (Json_util.kind_name other)

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
