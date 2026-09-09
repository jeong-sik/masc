(* The async request-control tools are declared in
   config/tools/keeper_composition_{status,cancel}.toml. Two things here have
   a second producer to disagree with, and only those are checked: the loaded
   input schema against the request-id shape these tools used to build inline,
   and the tool names against Keeper_tool_composition_catalog.

   The descriptions are not among them. They have one producer -- the TOML --
   and the schema is read straight out of it, so a pinned copy of the prose
   could only report that somebody edited the prose. It did exactly that:
   #32741 split both sentences so the first fits the one line a deferred
   tool's listing shows, which was the point of that PR, and the pin sat red
   until this file was next read. *)

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
        ; Alcotest.test_case "names match the catalog" `Quick
            test_names_match_the_catalog
        ] )
    ]
;;
