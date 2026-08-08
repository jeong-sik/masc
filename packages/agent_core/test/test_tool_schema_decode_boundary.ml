(** The two boundaries a tool schema crosses, pinned to their return types.

    {!Types.input_schema_of_json} decides what may be stored as an
    authoritative tool argument schema: a JSON object with unique keys, and
    nothing else. Before this, any non-[`Null] value was accepted, so a bare
    string or a list could be handed to a provider as an argument schema.

    {!Types.tool_schema_of_json} decodes persisted checkpoints and session
    payloads. Before this, it read its fields with [Yojson.Safe.Util.to_list],
    [to_string] and [to_bool_option], which raise [Type_error] — so a malformed
    payload escaped the [result] the signature advertises. Every case below
    asserts an [Error] value {e and} that nothing was raised. *)

open Alcotest
open Agent_sdk

let input_schema_error =
  testable Types.pp_input_schema_error Types.equal_input_schema_error
;;

(* ── input_schema_of_json: only objects with unique keys ─── *)

let check_rejected_shape name value shape =
  check
    (result
       (of_pp (fun formatter _ -> Format.pp_print_string formatter "<schema>"))
       input_schema_error)
    (name ^ " is not a schema")
    (Error (Types.Input_schema_not_an_object shape))
    (Types.input_schema_of_json value)
;;

let test_explicit_null_is_not_a_schema () =
  check_rejected_shape "explicit null" `Null Types.Json_null
;;

let test_string_is_not_a_schema () =
  check_rejected_shape "a string" (`String "object") Types.Json_string
;;

let test_integer_is_not_a_schema () =
  check_rejected_shape "an integer" (`Int 1) Types.Json_int
;;

let test_float_is_not_a_schema () =
  check_rejected_shape "a number" (`Float 1.5) Types.Json_float
;;

let test_bool_is_not_a_schema () =
  check_rejected_shape "a boolean" (`Bool true) Types.Json_bool
;;

let test_list_is_not_a_schema () =
  check_rejected_shape "an array" (`List [ `String "object" ]) Types.Json_list
;;

let test_rejection_names_the_offending_shape () =
  check
    string
    "message names the shape that arrived"
    "input_schema must be a JSON object, got an array"
    (Types.input_schema_error_to_string
       (Types.Input_schema_not_an_object Types.Json_list))
;;

(* Yojson keeps both entries of a repeated key, so uniqueness is not implied by
   the type and a duplicate would silently pick one meaning downstream. *)
let test_duplicate_root_key_is_rejected () =
  check
    input_schema_error
    "duplicate root key"
    (Types.Input_schema_duplicate_keys { path = "input_schema"; keys = [ "type" ] })
    (match
       Types.input_schema_of_json
         (`Assoc [ "type", `String "object"; "type", `String "string" ])
     with
     | Error error -> error
     | Ok _ -> failf "expected a duplicate-key rejection")
;;

let test_duplicate_nested_key_is_rejected () =
  let schema : Yojson.Safe.t =
    `Assoc
      [ "type", `String "object"
      ; ( "properties"
        , `Assoc
            [ "city", `Assoc [ "type", `String "string" ]
            ; "city", `Assoc [ "type", `String "integer" ]
            ] )
      ]
  in
  check
    input_schema_error
    "duplicate nested key, named by path"
    (Types.Input_schema_duplicate_keys
       { path = "input_schema.properties"; keys = [ "city" ] })
    (match Types.input_schema_of_json schema with
     | Error error -> error
     | Ok _ -> failf "expected a duplicate-key rejection")
;;

(* The constructor is the only producer of an authoritative schema, so the gate
   has to hold there too and not only on the raw predicate. *)
let test_constructor_refuses_a_non_object_schema () =
  match
    Types.tool_schema_of_input_schema
      ~name:"read_file"
      ~description:"Read a file"
      ~input_schema:(`String "object")
      ()
  with
  | Ok _ -> fail "expected a non-object schema to be refused"
  | Error detail ->
    check
      string
      "names the shape"
      "input_schema must be a JSON object, got a string"
      detail
;;

(* ── tool_schema_of_json is total ─────────────────────────── *)

let decode label json =
  match Types.tool_schema_of_json json with
  | result -> result
  | exception exn -> failf "%s raised %s" label (Printexc.to_string exn)
;;

let check_decode_error label json =
  match decode label json with
  | Ok _ -> failf "%s: expected Error" label
  | Error detail ->
    check bool (label ^ ": error is not empty") true (String.length detail > 0);
    detail
;;

let well_formed_fields =
  [ "name", `String "read_file"; "description", `String "Read a file" ]
;;

let with_fields extra : Yojson.Safe.t = `Assoc (well_formed_fields @ extra)

let test_decode_rejects_non_object_payload () =
  check
    string
    "names the shape"
    "tool_schema must be a JSON object, got an array"
    (check_decode_error "non-object payload" (`List []))
;;

let test_decode_rejects_parameters_that_are_not_a_list () =
  check
    string
    "names the field and the shape"
    "tool_schema.parameters must be an array, got an object"
    (check_decode_error "parameters not a list" (with_fields [ "parameters", `Assoc [] ]))
;;

let test_decode_rejects_a_param_name_that_is_not_a_string () =
  check
    string
    "names the field and the shape"
    "tool_param.name must be a string, got an integer"
    (check_decode_error
       "param name not a string"
       (with_fields
          [ ( "parameters"
            , `List
                [ `Assoc
                    [ "name", `Int 1
                    ; "description", `String ""
                    ; "param_type", `String "string"
                    ; "required", `Bool true
                    ]
                ] )
          ]))
;;

let test_decode_rejects_a_param_that_is_not_an_object () =
  check
    string
    "names the shape"
    "tool_param must be a JSON object, got a string"
    (check_decode_error
       "param not an object"
       (with_fields [ "parameters", `List [ `String "city" ] ]))
;;

let test_decode_rejects_strict_that_is_not_a_bool () =
  check
    string
    "names the field and the shape"
    "tool_schema.strict must be a boolean, got a string"
    (check_decode_error
       "strict not a bool"
       (with_fields [ "parameters", `List []; "strict", `String "true" ]))
;;

let test_decode_rejects_a_name_that_is_not_a_string () =
  check
    string
    "names the field and the shape"
    "tool_schema.name must be a string, got a boolean"
    (check_decode_error
       "name not a string"
       (`Assoc
           [ "name", `Bool true
           ; "description", `String "Read a file"
           ; "parameters", `List []
           ]))
;;

let test_decode_rejects_a_missing_name () =
  check
    string
    "names the missing field"
    "tool_schema fields mismatch (missing=[name], unknown=[], duplicates=[])"
    (check_decode_error
       "missing name"
       (`Assoc [ "description", `String "Read a file"; "parameters", `List [] ]))
;;

let test_decode_rejects_duplicate_and_unknown_top_level_fields () =
  check
    string
    "duplicate is named"
    "tool_schema fields mismatch (missing=[], unknown=[], duplicates=[name])"
    (check_decode_error
       "duplicate name"
       (`Assoc
           [ "name", `String "first"
           ; "name", `String "second"
           ; "description", `String "Read a file"
           ; "parameters", `List []
           ]));
  check
    string
    "unknown is named"
    "tool_schema fields mismatch (missing=[], unknown=[legacy_schema], duplicates=[])"
    (check_decode_error
       "unknown field"
       (with_fields [ "parameters", `List []; "legacy_schema", `Assoc [] ]))
;;

let test_decode_rejects_explicit_null_strict () =
  check
    string
    "manual absence is key omission"
    "tool_schema.strict must be a boolean, got null"
    (check_decode_error
       "strict null"
       (with_fields [ "parameters", `List []; "strict", `Null ]))
;;

(* [Some `Null] used to be representable and collapsed back to [None] on the
   derived round-trip. It is now unreachable, and a payload that spells it out
   is refused rather than silently reinterpreted as "no schema". *)
let test_decode_rejects_input_schema_that_is_not_an_object () =
  check
    string
    "names the shape"
    "input_schema must be a JSON object, got null"
    (check_decode_error
       "input_schema null"
       (with_fields [ "parameters", `List []; "input_schema", `Null ]));
  check
    string
    "names the shape"
    "input_schema must be a JSON object, got an array"
    (check_decode_error
       "input_schema list"
       (with_fields [ "parameters", `List []; "input_schema", `List [] ]))
;;

(* A persisted pair that disagrees is not a value the private constructors
   could have produced. Reject it rather than silently discarding one side. *)
let test_decode_rejects_parameters_that_disagree_with_input_schema () =
  let input_schema : Yojson.Safe.t =
    `Assoc
      [ "type", `String "object"
      ; ( "properties"
        , `Assoc
            [ "city", `Assoc [ "type", `String "string"; "description", `String "City" ] ]
        )
      ; "required", `List [ `String "city" ]
      ]
  in
  let payload =
    with_fields
      [ ( "parameters"
        , `List
            [ `Assoc
                [ "name", `String "stale"
                ; "description", `String "no longer in the schema"
                ; "param_type", `String "boolean"
                ; "required", `Bool false
                ]
            ] )
      ; "input_schema", input_schema
      ]
  in
  let derived_payload =
    let stale_parameters =
      [ { Types.name = "stale"
        ; description = "no longer in the schema"
        ; param_type = Types.Boolean
        ; required = false
        }
      ]
    in
    match
      Types.tool_schema_of_params
        ~name:"read_file"
        ~description:"Read a file"
        ~parameters:stale_parameters
        ()
      |> Types.tool_schema_to_yojson
    with
    | `Assoc fields ->
      `Assoc
        (("input_schema", input_schema)
         :: List.filter (fun (key, _) -> not (String.equal key "input_schema")) fields)
    | _ -> fail "derived tool_schema encoding must be an object"
  in
  let expected =
    "tool_schema.parameters must equal the projection of tool_schema.input_schema"
  in
  check
    string
    "manual decoder rejects the divergent pair"
    expected
    (check_decode_error "manual divergent pair" payload);
  match Types.tool_schema_of_yojson derived_payload with
  | Ok accepted ->
    failf
      "derived decoder accepted a divergent pair: %s"
      (Types.show_tool_schema accepted)
  | Error detail ->
    check string "derived decoder rejects the divergent pair" expected detail
;;

let test_derived_decoder_rejects_explicit_null_input_schema () =
  let schema =
    Types.tool_schema_of_params
      ~name:"read_file"
      ~description:"Read a file"
      ~parameters:[]
      ()
  in
  let payload =
    match Types.tool_schema_to_yojson schema with
    | `Assoc fields -> `Assoc (("input_schema", `Null) :: fields)
    | _ -> fail "derived tool_schema encoding must be an object"
  in
  match Types.tool_schema_of_yojson payload with
  | Ok _ -> fail "derived schema decoder accepted explicit null input_schema"
  | Error detail ->
    check
      string
      "present input_schema must be an object"
      "input_schema must be a JSON object, got null"
      detail
;;

let test_decode_validates_parameters_even_with_input_schema () =
  let input_schema : Yojson.Safe.t = `Assoc [ "type", `String "object" ] in
  check
    string
    "malformed derived view is still rejected"
    "tool_schema.parameters must be an array, got an object"
    (check_decode_error
       "malformed parameters with input_schema"
       (with_fields [ "parameters", `Assoc []; "input_schema", input_schema ]))
;;

(* ── tool_param_of_json is total ──────────────────────────── *)

let test_tool_param_decode_is_total () =
  let cases : (string * Yojson.Safe.t) list =
    [ "not an object", `String "city"
    ; "name not a string", `Assoc [ "name", `Int 1 ]
    ; ( "required not a bool"
      , `Assoc
          [ "name", `String "city"
          ; "description", `String ""
          ; "param_type", `String "string"
          ; "required", `String "yes"
          ] )
    ; ( "unknown param_type"
      , `Assoc
          [ "name", `String "city"
          ; "description", `String ""
          ; "param_type", `String "decimal"
          ; "required", `Bool true
          ] )
    ]
  in
  List.iter
    (fun (label, json) ->
       match Types.tool_param_of_json json with
       | exception exn -> failf "%s raised %s" label (Printexc.to_string exn)
       | Ok _ -> failf "%s: expected Error" label
       | Error detail ->
         check bool (label ^ ": error is not empty") true (String.length detail > 0))
    cases
;;

let test_tool_param_decode_rejects_duplicate_and_unknown_fields () =
  let common =
    [ "name", `String "city"
    ; "description", `String ""
    ; "param_type", `String "string"
    ; "required", `Bool true
    ]
  in
  check
    string
    "duplicate param field is named"
    "tool_param fields mismatch (missing=[], unknown=[], duplicates=[required])"
    (match Types.tool_param_of_json (`Assoc (common @ [ "required", `Bool false ])) with
     | Ok _ -> fail "duplicate param field was accepted"
     | Error detail -> detail);
  check
    string
    "unknown param field is named"
    "tool_param fields mismatch (missing=[], unknown=[default], duplicates=[])"
    (match
       Types.tool_param_of_json (`Assoc (common @ [ "default", `String "Paris" ]))
     with
     | Ok _ -> fail "unknown param field was accepted"
     | Error detail -> detail)
;;

let derived_schema_error label json =
  match Types.tool_schema_of_yojson json with
  | Ok _ -> failf "%s: derived schema decoder accepted an ambiguous object" label
  | Error detail -> detail
;;

let derived_param_error label json =
  match Types.tool_param_of_yojson json with
  | Ok _ -> failf "%s: derived param decoder accepted an ambiguous object" label
  | Error detail -> detail
;;

let replace_assoc_field name value fields =
  (name, value) :: List.filter (fun (key, _) -> not (String.equal key name)) fields
;;

let test_derived_decoders_reject_duplicate_and_unknown_fields () =
  let parameter : Types.tool_param =
    { name = "city"; description = ""; param_type = Types.String; required = true }
  in
  let parameter_fields =
    match Types.tool_param_to_yojson parameter with
    | `Assoc fields -> fields
    | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      fail "derived tool_param encoding must be an object"
  in
  check
    string
    "derived param duplicate is named"
    "tool_param fields mismatch (missing=[], unknown=[], duplicates=[required])"
    (derived_param_error
       "duplicate derived param field"
       (`Assoc (parameter_fields @ [ "required", `Bool false ])));
  let schema =
    Types.tool_schema_of_params
      ~name:"weather"
      ~description:"Read weather"
      ~parameters:[ parameter ]
      ()
  in
  let schema_fields =
    match Types.tool_schema_to_yojson schema with
    | `Assoc fields -> fields
    | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      fail "derived tool_schema encoding must be an object"
  in
  check
    string
    "derived schema unknown field is named"
    "tool_schema fields mismatch (missing=[], unknown=[legacy_schema], duplicates=[])"
    (derived_schema_error
       "unknown derived schema field"
       (`Assoc (("legacy_schema", `Assoc []) :: schema_fields)));
  let unknown_parameter = `Assoc (("default", `String "Paris") :: parameter_fields) in
  check
    string
    "nested derived param unknown field is named"
    "tool_param fields mismatch (missing=[], unknown=[default], duplicates=[])"
    (derived_schema_error
       "unknown nested derived param field"
       (`Assoc
           (replace_assoc_field "parameters" (`List [ unknown_parameter ]) schema_fields)))
;;

let () =
  run
    "tool_schema_decode_boundary"
    [ ( "input_schema shape"
      , [ test_case "explicit null" `Quick test_explicit_null_is_not_a_schema
        ; test_case "string" `Quick test_string_is_not_a_schema
        ; test_case "integer" `Quick test_integer_is_not_a_schema
        ; test_case "float" `Quick test_float_is_not_a_schema
        ; test_case "boolean" `Quick test_bool_is_not_a_schema
        ; test_case "list" `Quick test_list_is_not_a_schema
        ; test_case
            "rejection names the shape"
            `Quick
            test_rejection_names_the_offending_shape
        ; test_case "duplicate root key" `Quick test_duplicate_root_key_is_rejected
        ; test_case "duplicate nested key" `Quick test_duplicate_nested_key_is_rejected
        ; test_case
            "constructor refuses a non-object schema"
            `Quick
            test_constructor_refuses_a_non_object_schema
        ] )
    ; ( "tool_schema_of_json totality"
      , [ test_case "non-object payload" `Quick test_decode_rejects_non_object_payload
        ; test_case
            "parameters not a list"
            `Quick
            test_decode_rejects_parameters_that_are_not_a_list
        ; test_case
            "param name not a string"
            `Quick
            test_decode_rejects_a_param_name_that_is_not_a_string
        ; test_case
            "param not an object"
            `Quick
            test_decode_rejects_a_param_that_is_not_an_object
        ; test_case
            "strict not a bool"
            `Quick
            test_decode_rejects_strict_that_is_not_a_bool
        ; test_case
            "name not a string"
            `Quick
            test_decode_rejects_a_name_that_is_not_a_string
        ; test_case "missing name" `Quick test_decode_rejects_a_missing_name
        ; test_case
            "duplicate and unknown top-level fields"
            `Quick
            test_decode_rejects_duplicate_and_unknown_top_level_fields
        ; test_case "strict null" `Quick test_decode_rejects_explicit_null_strict
        ; test_case
            "input_schema not an object"
            `Quick
            test_decode_rejects_input_schema_that_is_not_an_object
        ; test_case
            "parameters disagree with input_schema"
            `Quick
            test_decode_rejects_parameters_that_disagree_with_input_schema
        ; test_case
            "parameters validated with input_schema"
            `Quick
            test_decode_validates_parameters_even_with_input_schema
        ] )
    ; ( "tool_param_of_json totality"
      , [ test_case "malformed params" `Quick test_tool_param_decode_is_total
        ; test_case
            "duplicate and unknown fields"
            `Quick
            test_tool_param_decode_rejects_duplicate_and_unknown_fields
        ] )
    ; ( "derived decoder exact fields"
      , [ test_case
            "explicit null input_schema"
            `Quick
            test_derived_decoder_rejects_explicit_null_input_schema
        ; test_case
            "duplicate and unknown fields"
            `Quick
            test_derived_decoders_reject_duplicate_and_unknown_fields
        ] )
    ]
;;
