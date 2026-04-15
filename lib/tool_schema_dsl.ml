(** Tool_schema_dsl — shared JSON Schema builder helpers for MCP tool definitions.

    Reduces per-property boilerplate from ~5 lines of raw Yojson.Safe.t
    to 1 line. Consolidated from duplicate definitions in
    Sdk_tool_contract. *)

let string_prop description =
  `Assoc [ ("type", `String "string"); ("description", `String description) ]

let integer_prop ?default description =
  `Assoc
    ([ ("type", `String "integer"); ("description", `String description) ]
    @ (match default with Some v -> [ ("default", `Int v) ] | None -> []))

let boolean_prop ?default description =
  `Assoc
    ([ ("type", `String "boolean"); ("description", `String description) ]
    @ (match default with Some v -> [ ("default", `Bool v) ] | None -> []))

let string_array_prop description =
  `Assoc
    [
      ("type", `String "array");
      ("description", `String description);
      ("items", `Assoc [ ("type", `String "string") ]);
    ]

let object_schema ?(required = []) properties =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc properties);
      ("required", `List (List.map (fun k -> `String k) required));
    ]
