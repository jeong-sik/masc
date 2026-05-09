(** RFC-0057 Phase 0 regression test.

    Guards [bin/gen_tool_descriptors.ml] output against the
    hand-written schema in [Tool_schemas_misc] for [masc_config].
    A drift in description text, enum ordering, additionalProperties,
    or any nested Yojson value fails this test before the change
    reaches an LLM client.

    Phase 1 will replace [Tool_schemas_misc.masc_config] with the
    generated schema and remove this comparison; until then, the
    two schemas live side-by-side and this test pins them
    field-for-field. Same pattern as RFC-0054 PR-3's
    [test_shell_ir_typed_walkers_gen]. *)

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

let () =
  Alcotest.run
    "tool_descriptors_gen"
    [ ( "masc_config field-by-field"
      , [ Alcotest.test_case "name" `Quick test_masc_config_name_matches
        ; Alcotest.test_case "description" `Quick test_masc_config_description_matches
        ; Alcotest.test_case
            "input_schema"
            `Quick
            test_masc_config_input_schema_matches
        ] )
    ]
;;
