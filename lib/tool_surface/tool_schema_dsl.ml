(** Tool_schema_dsl — shared JSON Schema builder helpers for MCP tool definitions.

    Reduces per-property boilerplate from ~5 lines of raw Yojson.Safe.t
    to 1 line. Consolidated from duplicate definitions in
    Agent_core_tool_contract. *)

let string_prop description =
  `Assoc [ ("type", `String "string"); ("description", `String description) ]

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

  (* An empty ["required"] says nothing an absent one does not, and both
     readers already fold them together: llm_provider/types.ml answers [None]
     and [`Null] with [Ok []], and tool_input_validation.ml treats a
     non-matching key the same way. Emitting it spends bytes in every turn's
     tool list to say nothing, and twenty-six of the eighty-two published
     tools already omit it. *)
let object_schema ?(required = []) properties =
  `Assoc
    ([ ("type", `String "object"); ("properties", `Assoc properties) ]
     @ (match required with
        | [] -> []
        | _ :: _ -> [ ("required", `List (List.map (fun k -> `String k) required)) ])
     @ [ ("additionalProperties", `Bool false) ])
