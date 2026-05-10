(** RFC-0057 Phase 2 regression test.

    Guards [bin/gen_tool_descriptors.ml] output against the
    effective schema exposed by [Tool_schemas_misc] for [masc_config],
    [masc_code_read], and [masc_tool_help].

    Phase 2 lifted spec types into [lib/tool_schemas_specs/] and added
    the 3rd generated tool. Hand-written entries for all three tools
    were removed from [Tool_schemas_misc]; generated schemas are the
    SSOT. The test pins generated vs effective field-for-field.

    Same pattern as RFC-0054 PR-3's [test_shell_ir_typed_walkers_gen]. *)

open Masc_domain

let yojson_testable : Yojson.Safe.t Alcotest.testable =
  Alcotest.testable
    (fun fmt v -> Format.fprintf fmt "%s" (Yojson.Safe.pretty_to_string v))
    Yojson.Safe.equal
;;

let find_by_name name (schemas : tool_schema list) : tool_schema =
  match List.find_opt (fun s -> String.equal s.name name) schemas with
  | Some s -> s
  | None ->
    Alcotest.failf
      "tool %S not in schemas (have: %s)"
      name
      (String.concat ", " (List.map (fun s -> s.name) schemas))
;;

let test_masc_config_name_matches () =
  let gen = find_by_name "masc_config" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_config" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_config name" hand.name gen.name
;;

let test_masc_config_description_matches () =
  let gen = find_by_name "masc_config" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_config" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_config description" hand.description gen.description
;;

let test_masc_config_input_schema_matches () =
  let gen = find_by_name "masc_config" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_config" Tool_schemas_misc.schemas in
  Alcotest.check
    yojson_testable
    "masc_config input_schema (Yojson.Safe.equal)"
    hand.input_schema
    gen.input_schema
;;

let test_masc_code_read_name_matches () =
  let gen = find_by_name "masc_code_read" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_code_read" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_code_read name" hand.name gen.name
;;

let test_masc_code_read_description_matches () =
  let gen = find_by_name "masc_code_read" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_code_read" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_code_read description" hand.description gen.description
;;

let test_masc_code_read_input_schema_matches () =
  let gen = find_by_name "masc_code_read" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_code_read" Tool_schemas_misc.schemas in
  Alcotest.check
    yojson_testable
    "masc_code_read input_schema (Yojson.Safe.equal)"
    hand.input_schema
    gen.input_schema
;;

let test_masc_tool_help_name_matches () =
  let gen = find_by_name "masc_tool_help" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_tool_help" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_tool_help name" hand.name gen.name
;;

let test_masc_tool_help_description_matches () =
  let gen = find_by_name "masc_tool_help" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_tool_help" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_tool_help description" hand.description gen.description
;;

let test_masc_tool_help_input_schema_matches () =
  let gen = find_by_name "masc_tool_help" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_tool_help" Tool_schemas_misc.schemas in
  Alcotest.check
    yojson_testable
    "masc_tool_help input_schema (Yojson.Safe.equal)"
    hand.input_schema
    gen.input_schema
;;

let () =
  Alcotest.run
    "tool_descriptors_gen"
    [ ( "masc_config field-by-field"
      , [ Alcotest.test_case "name" `Quick test_masc_config_name_matches
        ; Alcotest.test_case "description" `Quick test_masc_config_description_matches
        ; Alcotest.test_case "input_schema" `Quick test_masc_config_input_schema_matches
        ] )
    ; ( "masc_code_read field-by-field"
      , [ Alcotest.test_case "name" `Quick test_masc_code_read_name_matches
        ; Alcotest.test_case "description" `Quick test_masc_code_read_description_matches
        ; Alcotest.test_case
            "input_schema"
            `Quick
            test_masc_code_read_input_schema_matches
        ] )
    ; ( "masc_tool_help field-by-field"
      , [ Alcotest.test_case "name" `Quick test_masc_tool_help_name_matches
        ; Alcotest.test_case "description" `Quick test_masc_tool_help_description_matches
        ; Alcotest.test_case
            "input_schema"
            `Quick
            test_masc_tool_help_input_schema_matches
        ] )
    ]
;;
