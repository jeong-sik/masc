(** Regression tests for authoritative tool input schemas.

    A caller-supplied JSON Schema used to be converted to [Types.tool_param
    list] and then rebuilt by {!Types.params_to_input_schema}, which keeps only
    type, description and required. Everything else — [minimum], [maximum],
    [default], [enum], nested properties — was destroyed before the tool
    definition reached the provider. These tests pin the authoritative schema
    to the wire. *)

open Alcotest
open Agent_sdk

(* The production case that surfaced the loss: a byte cap the model must stay
   inside. Named so the expectations below cannot drift from the fixture. *)
let max_bytes_minimum = 1
let max_bytes_maximum = 65536
let max_bytes_default = 65536
let cursor_enum = [ "start"; "end" ]

let rich_input_schema : Yojson.Safe.t =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ ( "max_bytes"
            , `Assoc
                [ "type", `String "integer"
                ; "description", `String "Maximum bytes to read"
                ; "minimum", `Int max_bytes_minimum
                ; "maximum", `Int max_bytes_maximum
                ; "default", `Int max_bytes_default
                ] )
          ; ( "cursor"
            , `Assoc
                [ "type", `String "string"
                ; "description", `String "Where to read from"
                ; "enum", `List (List.map (fun value -> `String value) cursor_enum)
                ] )
          ; ( "window"
            , `Assoc
                [ "type", `String "object"
                ; "description", `String "Nested window bounds"
                ; ( "properties"
                  , `Assoc
                      [ "offset", `Assoc [ "type", `String "integer" ]
                      ; "length", `Assoc [ "type", `String "integer" ]
                      ] )
                ] )
          ] )
    ; "required", `List [ `String "max_bytes" ]
    ]
;;

let noop_handler _input = Ok { Types.content = ""; _meta = None }

let json =
  testable
    (fun formatter value ->
       Format.pp_print_string formatter (Yojson.Safe.to_string value))
    ( = )
;;

let tool_from_rich_schema () : Tool.t =
  match
    Mcp.tool_of_input_schema_result
      ~name:"read_file"
      ~description:"Read a file"
      ~input_schema:rich_input_schema
      noop_handler
  with
  | Ok tool -> tool
  | Error detail -> failf "tool_of_input_schema_result: %s" detail
;;

let member name value = Yojson.Safe.Util.member name value

(* ── Wire fidelity ────────────────────────────────────────── *)

let test_authoritative_schema_reaches_the_wire () =
  let tool = tool_from_rich_schema () in
  let emitted = Tool.schema_to_json tool |> member "input_schema" in
  check json "input_schema emitted verbatim" rich_input_schema emitted;
  let properties = emitted |> member "properties" in
  let max_bytes = properties |> member "max_bytes" in
  check
    int
    "minimum survives"
    max_bytes_minimum
    (max_bytes |> member "minimum" |> Yojson.Safe.Util.to_int);
  check
    int
    "maximum survives"
    max_bytes_maximum
    (max_bytes |> member "maximum" |> Yojson.Safe.Util.to_int);
  check
    int
    "default survives"
    max_bytes_default
    (max_bytes |> member "default" |> Yojson.Safe.Util.to_int);
  check
    (list string)
    "enum survives"
    cursor_enum
    (properties
     |> member "cursor"
     |> member "enum"
     |> Yojson.Safe.Util.to_list
     |> List.map Yojson.Safe.Util.to_string);
  check
    (list string)
    "nested properties survive"
    [ "length"; "offset" ]
    (properties
     |> member "window"
     |> member "properties"
     |> Yojson.Safe.Util.to_assoc
     |> List.map fst
     |> List.sort String.compare)
;;

let test_derived_schema_unchanged_without_input_schema () =
  let parameters =
    [ { Types.name = "expr"
      ; description = "Expression"
      ; param_type = Types.String
      ; required = true
      }
    ; { Types.name = "precision"
      ; description = "Decimal places"
      ; param_type = Types.Integer
      ; required = false
      }
    ]
  in
  let tool = Tool.create ~name:"calc" ~description:"Calculate" ~parameters noop_handler in
  (* Pinned against a literal rather than against
     [Types.params_to_input_schema parameters]. In the [None] branch
     [schema_to_json] IS that function, so comparing the two puts the same
     call on both sides of the check and any regression inside it cancels
     out — dropping every parameter description passed that way. *)
  check
    json
    "derived from parameters when no authoritative schema"
    (`Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "expr"
                , `Assoc [ "type", `String "string"; "description", `String "Expression" ]
                )
              ; ( "precision"
                , `Assoc
                    [ "type", `String "integer"; "description", `String "Decimal places" ]
                )
              ] )
        ; "required", `List [ `String "expr" ]
        ])
    (Tool.schema_to_json tool |> member "input_schema")
;;

(* ── parameters / input_schema invariant ──────────────────── *)

let tool_param = testable Types.pp_tool_param ( = )

(* Written out rather than computed as [Mcp.json_schema_to_params
   rich_input_schema]. That projection is what the constructors run, so calling
   it here would put it on both sides and cancel out any regression inside it —
   a defect that drops every property description passes that way. These
   literals are the projection of [rich_input_schema] read off by hand. *)
let rich_schema_parameters =
  [ { Types.name = "max_bytes"
    ; description = "Maximum bytes to read"
    ; param_type = Types.Integer
    ; required = true
    }
  ; { Types.name = "cursor"
    ; description = "Where to read from"
    ; param_type = Types.String
    ; required = false
    }
  ; { Types.name = "window"
    ; description = "Nested window bounds"
    ; param_type = Types.Object
    ; required = false
    }
  ]
;;

let check_parameters_derived_from_schema label (schema : Types.tool_schema) =
  check
    (option json)
    (label ^ ": authoritative schema kept")
    (Some rich_input_schema)
    schema.input_schema;
  check
    (list tool_param)
    (label ^ ": parameters are the projection of the schema")
    rich_schema_parameters
    schema.parameters
;;

let test_tool_parameters_are_derived_from_the_schema () =
  let tool = tool_from_rich_schema () in
  check_parameters_derived_from_schema "Mcp.tool_of_input_schema_result" tool.schema
;;

let test_middleware_schema_keeps_its_source () =
  match
    Tool_middleware.tool_schema_of_json_result
      ~name:"read_file"
      ~description:"Read a file"
      rich_input_schema
  with
  | Error detail -> failf "tool_schema_of_json_result: %s" detail
  | Ok schema ->
    check_parameters_derived_from_schema
      "Tool_middleware.tool_schema_of_json_result"
      schema
;;

let test_invalid_schema_names_the_failing_property () =
  let unsupported_type_schema : Yojson.Safe.t =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "count", `Assoc [ "type", `String "decimal" ] ]
      ]
  in
  match
    Mcp.tool_of_input_schema_result
      ~name:"broken"
      ~description:"Broken"
      ~input_schema:unsupported_type_schema
      noop_handler
  with
  | Ok _ -> fail "expected the unsupported type to be rejected"
  | Error detail ->
    check
      bool
      "names the tool and the offending type"
      true
      (Util.contains_substring_ci ~haystack:detail ~needle:"broken"
       && Util.contains_substring_ci ~haystack:detail ~needle:"decimal")
;;

let test_composed_properties_do_not_block_authoritative_schema () =
  let input_schema : Yojson.Safe.t =
    `Assoc
      [ "type", `String "object"
      ; ( "$defs"
        , `Assoc
            [ ( "location"
              , `Assoc
                  [ "type", `String "object"
                  ; "properties", `Assoc [ "city", `Assoc [ "type", `String "string" ] ]
                  ] )
            ] )
      ; ( "properties"
        , `Assoc
            [ "location", `Assoc [ "$ref", `String "#/$defs/location" ]
            ; ( "label"
              , `Assoc
                  [ ( "anyOf"
                    , `List
                        [ `Assoc [ "type", `String "string" ]
                        ; `Assoc [ "type", `String "null" ]
                        ] )
                  ] )
            ; ( "choice"
              , `Assoc
                  [ ( "oneOf"
                    , `List
                        [ `Assoc [ "const", `String "left" ]
                        ; `Assoc [ "const", `String "right" ]
                        ] )
                  ] )
            ; "fixed", `Assoc [ "const", `String "current" ]
            ; "mode", `Assoc [ "enum", `List [ `String "fast"; `String "safe" ] ]
            ] )
      ; "required", `List [ `String "location" ]
      ]
  in
  match
    Types.tool_schema_of_input_schema
      ~name:"composed"
      ~description:"Composed schema"
      ~input_schema
      ()
  with
  | Error detail -> failf "valid composed schema rejected: %s" detail
  | Ok schema ->
    check
      (option json)
      "authoritative schema preserved"
      (Some input_schema)
      schema.input_schema;
    check
      (list string)
      "only inferable properties enter the lossy parameter view"
      [ "fixed"; "mode" ]
      (List.map (fun (param : Types.tool_param) -> param.name) schema.parameters)
;;

let authoritative_schema_exn input_schema =
  match
    Types.tool_schema_of_input_schema
      ~name:"authoritative"
      ~description:"Authoritative schema"
      ~input_schema
      ()
  with
  | Ok schema -> schema
  | Error detail -> failf "authoritative schema rejected: %s" detail
;;

let test_nullable_property_validation_uses_authoritative_schema () =
  let schema =
    authoritative_schema_exn
      (`Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ "label", `Assoc [ "type", `List [ `String "string"; `String "null" ] ] ]
            )
          ; "required", `List [ `String "label" ]
          ])
  in
  let expect_valid label input =
    match Tool_input_validation.validate schema input with
    | Tool_input_validation.Valid exact -> check json label input exact
    | Tool_input_validation.Invalid _ -> failf "%s: expected valid" label
  in
  expect_valid "nullable accepts null" (`Assoc [ "label", `Null ]);
  expect_valid "nullable accepts string" (`Assoc [ "label", `String "ready" ]);
  match Tool_input_validation.validate schema (`Assoc [ "label", `Int 1 ]) with
  | Tool_input_validation.Invalid _ -> ()
  | Tool_input_validation.Valid _ -> fail "nullable string accepted an integer"
;;

let test_integer_validation_accepts_integral_floats () =
  let schema =
    authoritative_schema_exn
      (`Assoc
          [ "type", `String "object"
          ; "properties", `Assoc [ "count", `Assoc [ "type", `String "integer" ] ]
          ; "required", `List [ `String "count" ]
          ])
  in
  (match Tool_input_validation.validate schema (`Assoc [ "count", `Float 1.0 ]) with
   | Tool_input_validation.Valid _ -> ()
   | Tool_input_validation.Invalid _ -> fail "JSON Schema integer rejected 1.0");
  match Tool_input_validation.validate schema (`Assoc [ "count", `Float 1.5 ]) with
  | Tool_input_validation.Invalid _ -> ()
  | Tool_input_validation.Valid _ -> fail "JSON Schema integer accepted 1.5"
;;

let test_boolean_property_schemas_are_preserved_and_enforced () =
  let input_schema : Yojson.Safe.t =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "open_value", `Bool true; "closed_value", `Bool false ]
      ; "required", `List [ `String "open_value" ]
      ]
  in
  let schema = authoritative_schema_exn input_schema in
  check (option json) "boolean schemas preserved" (Some input_schema) schema.input_schema;
  check int "boolean schemas omitted from projection" 0 (List.length schema.parameters);
  (match Tool_input_validation.validate schema (`Assoc [ "open_value", `List [] ]) with
   | Tool_input_validation.Valid _ -> ()
   | Tool_input_validation.Invalid _ -> fail "true property schema rejected a value");
  match
    Tool_input_validation.validate
      schema
      (`Assoc [ "open_value", `Null; "closed_value", `String "forbidden" ])
  with
  | Tool_input_validation.Invalid _ -> ()
  | Tool_input_validation.Valid _ -> fail "false property schema accepted a value"
;;

let test_const_and_enum_validation_use_json_semantics () =
  let schema =
    authoritative_schema_exn
      (`Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "fixed"
                  , `Assoc
                      [ ( "const"
                        , `Assoc
                            [ "first", `Int 1
                            ; "nested", `List [ `Float 2.0; `Intlit "300" ]
                            ] )
                      ] )
                ; ( "choice"
                  , `Assoc
                      [ ( "enum"
                        , `List [ `Assoc [ "enabled", `Bool true; "count", `Intlit "4" ] ]
                        )
                      ] )
                ] )
          ; "required", `List [ `String "fixed"; `String "choice" ]
          ])
  in
  let reordered_equivalent =
    `Assoc
      [ "fixed", `Assoc [ "nested", `List [ `Int 2; `Float 300.0 ]; "first", `Float 1.0 ]
      ; "choice", `Assoc [ "count", `Float 4.0; "enabled", `Bool true ]
      ]
  in
  (match Tool_input_validation.validate schema reordered_equivalent with
   | Tool_input_validation.Valid exact ->
     check json "equivalent JSON accepted unchanged" reordered_equivalent exact
   | Tool_input_validation.Invalid _ ->
     fail "object key order or equivalent JSON numbers changed const/enum meaning");
  match
    Tool_input_validation.validate
      schema
      (`Assoc
          [ "fixed", `Assoc [ "first", `Int 1; "nested", `List [ `Int 2; `Int 301 ] ]
          ; "choice", `Assoc [ "enabled", `Bool true; "count", `Int 4 ]
          ])
  with
  | Tool_input_validation.Invalid _ -> ()
  | Tool_input_validation.Valid _ -> fail "a numerically different const was accepted"
;;

let test_explicit_non_object_root_schema_is_rejected () =
  let input_schema : Yojson.Safe.t =
    `Assoc [ "type", `String "array"; "items", `Assoc [ "type", `String "string" ] ]
  in
  match
    Types.tool_schema_of_input_schema
      ~name:"array_arguments"
      ~description:"Invalid tool argument root"
      ~input_schema
      ()
  with
  | Error detail ->
    check
      bool
      "error names object root contract"
      true
      (Util.contains_substring_ci ~haystack:detail ~needle:"object")
  | Ok _ -> fail "an explicitly array-valued tool input schema was accepted"
;;

let test_non_object_only_root_constraints_are_rejected () =
  let expect_rejected label input_schema =
    match
      Types.tool_schema_of_input_schema
        ~name:"non_object_arguments"
        ~description:label
        ~input_schema
        ()
    with
    | Error _ -> ()
    | Ok _ -> failf "%s: non-object-only schema was accepted" label
  in
  expect_rejected "array const" (`Assoc [ "const", `List [] ]);
  expect_rejected
    "array-only anyOf"
    (`Assoc [ "anyOf", `List [ `Assoc [ "type", `String "array" ] ] ]);
  match
    Types.tool_schema_of_input_schema
      ~name:"object_or_array_arguments"
      ~description:"Object remains possible"
      ~input_schema:
        (`Assoc
            [ ( "anyOf"
              , `List
                  [ `Assoc [ "type", `String "array" ]
                  ; `Assoc [ "type", `String "object" ]
                  ] )
            ])
      ()
  with
  | Ok _ -> ()
  | Error detail -> failf "mixed anyOf incorrectly excluded objects: %s" detail
;;

(* [Types.tool_schema] is [private], so there is no expression that pairs a
   [Some schema] with a [parameters] list of the caller's choosing: the two
   constructors below are the only producers and each derives one view from
   the other. That impossibility is enforced at compile time and cannot be
   asserted at run time; what is asserted here is what the constructors
   actually produce. *)

let test_input_schema_constructor_derives_its_parameters () =
  match
    Types.tool_schema_of_input_schema
      ~name:"read_file"
      ~description:"Read a file"
      ~input_schema:rich_input_schema
      ()
  with
  | Error detail -> failf "tool_schema_of_input_schema: %s" detail
  | Ok schema ->
    check_parameters_derived_from_schema "Types.tool_schema_of_input_schema" schema
;;

let test_params_constructor_leaves_no_authoritative_schema () =
  let parameters =
    [ { Types.name = "expr"
      ; description = "Expression"
      ; param_type = Types.String
      ; required = true
      }
    ]
  in
  let schema =
    Types.tool_schema_of_params ~name:"calc" ~description:"Calculate" ~parameters ()
  in
  check (option json) "no authoritative schema" None schema.input_schema;
  check bool "parameters kept verbatim" true (schema.parameters = parameters)
;;

(* ── tool_schema JSON round-trips ─────────────────────────── *)

let sample_parameters =
  [ { Types.name = "max_bytes"
    ; description = "Maximum bytes to read"
    ; param_type = Types.Integer
    ; required = true
    }
  ]
;;

let check_manual_roundtrip label (schema : Types.tool_schema) =
  match Types.tool_schema_of_json (Types.tool_schema_to_json schema) with
  | Error detail -> failf "%s: tool_schema_of_json: %s" label detail
  | Ok decoded -> check bool (label ^ ": record preserved") true (decoded = schema)
;;

let check_derived_roundtrip label (schema : Types.tool_schema) =
  match Types.tool_schema_of_yojson (Types.tool_schema_to_yojson schema) with
  | Error detail -> failf "%s: tool_schema_of_yojson: %s" label detail
  | Ok decoded -> check bool (label ^ ": record preserved") true (decoded = schema)
;;

let test_tool_schema_json_roundtrip () =
  let without =
    Types.tool_schema_of_params
      ~name:"read_file"
      ~description:"Read a file"
      ~parameters:sample_parameters
      ()
  in
  let with_schema =
    match
      Types.tool_schema_of_input_schema
        ~name:"read_file"
        ~description:"Read a file"
        ~input_schema:rich_input_schema
        ()
    with
    | Ok schema -> schema
    | Error detail -> failf "tool_schema_of_input_schema: %s" detail
  in
  check
    bool
    "input_schema omitted when None"
    false
    (List.mem_assoc
       "input_schema"
       (Yojson.Safe.Util.to_assoc (Types.tool_schema_to_json without)));
  check
    json
    "input_schema emitted verbatim when Some"
    rich_input_schema
    (Types.tool_schema_to_json with_schema |> member "input_schema");
  check_manual_roundtrip "manual without input_schema" without;
  check_manual_roundtrip "manual with input_schema" with_schema;
  check_derived_roundtrip "derived without input_schema" without;
  check_derived_roundtrip "derived with input_schema" with_schema
;;

(* ── schema source × handler kind ─────────────────────────── *)

(* The tool that produced the incident is built with an execution-environment
   handler, and until [of_schema] existed the authoritative source was only
   reachable from the plain-handler constructor. This pins the combination
   itself: the schema must arrive verbatim AND the handler must still receive
   its execution environment. *)
let test_authoritative_schema_rides_an_execution_env_handler () =
  let seen_invocation = ref None in
  let handler execution_env _input =
    seen_invocation := Tool.Execution_env.invocation execution_env;
    Ok { Types.content = "ok"; _meta = None }
  in
  let tool =
    match
      Types.tool_schema_of_input_schema
        ~name:"read_file"
        ~description:"Read a file"
        ~input_schema:rich_input_schema
        ()
    with
    | Error detail -> failf "tool_schema_of_input_schema: %s" detail
    | Ok schema -> Tool.of_schema schema handler
  in
  check
    json
    "authoritative schema survives the execution-env handler"
    rich_input_schema
    (Tool.schema_to_json tool |> member "input_schema");
  check
    (list tool_param)
    "parameters still the projection"
    rich_schema_parameters
    tool.schema.parameters;
  let invocation =
    Tool_contract.Invocation.create
      ~tool_use_id:"call-1"
      ~turn:0
      ~schedule:
        { planned_index = 0
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Tool_contract.Serial
        }
      ~completion:Tool_contract.Continue_after_success
  in
  let (_ : Types.tool_result) = Tool.execute ~invocation tool `Null in
  check
    (option string)
    "handler received its execution environment"
    (Some "call-1")
    (Option.map Tool_contract.Invocation.tool_use_id !seen_invocation)
;;

let test_context_handler_still_refuses_a_missing_context () =
  let tool =
    Tool.of_schema
      (Types.tool_schema_of_params
         ~name:"ctx"
         ~description:"Needs context"
         ~parameters:[]
         ())
      (Tool.requiring_context (fun _context _input ->
         Ok { Types.content = "unexpected"; _meta = None }))
  in
  match Tool.execute tool `Null with
  | Ok _ -> fail "expected the missing context to be refused"
  | Error { message; recoverable; _ } ->
    check
      string
      "names the missing context"
      "context-aware tool requires explicit context"
      message;
    check bool "not recoverable" false recoverable
;;

(* [input_schema = None] is encoded by omitting the key. The derived decoder
   must preserve that current parameter-derived schema representation. *)
let test_payload_without_the_key_decodes () =
  let payload : Yojson.Safe.t =
    `Assoc
      [ "name", `String "read_file"
      ; "description", `String "Read a file"
      ; ( "parameters"
        , `List
            [ `Assoc
                [ "name", `String "path"
                ; "description", `String "Path"
                ; "param_type", `List [ `String "String" ]
                ; "required", `Bool true
                ]
            ] )
      ; "strict", `Null
      ]
  in
  match Types.tool_schema_of_yojson payload with
  | Error detail -> failf "payload without input_schema rejected: %s" detail
  | Ok schema ->
    check
      (option json)
      "absent key means no authoritative schema"
      None
      schema.input_schema;
    check
      (list tool_param)
      "parameters decoded"
      [ { Types.name = "path"
        ; description = "Path"
        ; param_type = Types.String
        ; required = true
        }
      ]
      schema.parameters
;;

let () =
  run
    "tool_input_schema_fidelity"
    [ ( "wire fidelity"
      , [ test_case
            "authoritative schema reaches the wire"
            `Quick
            test_authoritative_schema_reaches_the_wire
        ; test_case
            "authoritative schema rides an execution-env handler"
            `Quick
            test_authoritative_schema_rides_an_execution_env_handler
        ; test_case
            "context handler still refuses a missing context"
            `Quick
            test_context_handler_still_refuses_a_missing_context
        ; test_case
            "payload without the input_schema key decodes"
            `Quick
            test_payload_without_the_key_decodes
        ; test_case
            "derived schema unchanged without input_schema"
            `Quick
            test_derived_schema_unchanged_without_input_schema
        ] )
    ; ( "invariant"
      , [ test_case
            "tool parameters derived from the schema"
            `Quick
            test_tool_parameters_are_derived_from_the_schema
        ; test_case
            "middleware schema keeps its source"
            `Quick
            test_middleware_schema_keeps_its_source
        ; test_case
            "invalid schema names the failing property"
            `Quick
            test_invalid_schema_names_the_failing_property
        ; test_case
            "composed properties keep the authoritative schema"
            `Quick
            test_composed_properties_do_not_block_authoritative_schema
        ; test_case
            "nullable validation uses the authoritative schema"
            `Quick
            test_nullable_property_validation_uses_authoritative_schema
        ; test_case
            "integer validation accepts integral floats"
            `Quick
            test_integer_validation_accepts_integral_floats
        ; test_case
            "boolean property schemas are preserved and enforced"
            `Quick
            test_boolean_property_schemas_are_preserved_and_enforced
        ; test_case
            "const and enum use JSON semantic equality"
            `Quick
            test_const_and_enum_validation_use_json_semantics
        ; test_case
            "explicit non-object root schema is rejected"
            `Quick
            test_explicit_non_object_root_schema_is_rejected
        ; test_case
            "non-object-only root constraints are rejected"
            `Quick
            test_non_object_only_root_constraints_are_rejected
        ; test_case
            "input_schema constructor derives its parameters"
            `Quick
            test_input_schema_constructor_derives_its_parameters
        ; test_case
            "params constructor leaves no authoritative schema"
            `Quick
            test_params_constructor_leaves_no_authoritative_schema
        ] )
    ; ( "round-trip"
      , [ test_case "tool_schema json round-trip" `Quick test_tool_schema_json_roundtrip ]
      )
    ]
;;
