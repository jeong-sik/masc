(* The async request-control tools' schema and prose come from
   config/tools/keeper_composition_{status,cancel}.toml, and the loaded schema
   is byte-identical to the request-id schema they used to build inline. *)

(* Byte-identity holds because the two TOMLs omit a description on the
   request_id param; adding one would put a "description" in the property
   and this pin would fail. That omission is deliberate, noted in each
   config/tools/keeper_composition_*.toml. *)
let expected_request_id_input_schema : Yojson.Safe.t =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ ( "request_id"
            , `Assoc [ "type", `String "string"; "minLength", `Int 1 ] ) ] )
    ; "required", `List [ `String "request_id" ]
    ; "additionalProperties", `Bool false
    ]
;;

let yojson = Alcotest.testable (fun ppf j -> Format.fprintf ppf "%s" (Yojson.Safe.to_string j)) Yojson.Safe.equal

let test_schemas_match_the_inline_form () =
  Alcotest.check yojson "status input schema"
    expected_request_id_input_schema
    Tool_schemas_composition_control.status_schema.input_schema;
  Alcotest.check yojson "cancel input schema"
    expected_request_id_input_schema
    Tool_schemas_composition_control.cancel_schema.input_schema
;;

let test_descriptions_are_the_authored_sentences () =
  Alcotest.(check string) "status description"
    "Read the exact durable status and structured result of one async Keeper composition request."
    Tool_schemas_composition_control.status_schema.description;
  Alcotest.(check string) "cancel description"
    "Request cancellation of one async Keeper composition by its exact durable request id."
    Tool_schemas_composition_control.cancel_schema.description
;;

let test_names_match_the_catalog () =
  Alcotest.(check string) "status name"
    Masc.Keeper_tool_composition_catalog.status_tool_name
    Tool_schemas_composition_control.status_schema.name;
  Alcotest.(check string) "cancel name"
    Masc.Keeper_tool_composition_catalog.cancel_tool_name
    Tool_schemas_composition_control.cancel_schema.name
;;

let () =
  Alcotest.run
    "composition-control-tool-toml"
    [ ( "toml"
      , [ Alcotest.test_case "schemas match the inline form" `Quick
            test_schemas_match_the_inline_form
        ; Alcotest.test_case "descriptions are the authored sentences" `Quick
            test_descriptions_are_the_authored_sentences
        ; Alcotest.test_case "names match the catalog" `Quick
            test_names_match_the_catalog
        ] )
    ]
;;
