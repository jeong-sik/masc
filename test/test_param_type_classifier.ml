(** Tests for sdk_tool_contract strict param_type classifier (#8832).

    Verifies that:
    - the strict [_opt] variant returns [Some] only for documented
      JSON Schema vocabulary,
    - unknown types (e.g. "null", future JSON Schema 2020-12 keywords)
      return [None] (no silent permissive default),
    - the back-compat wrapper preserves the legacy [String] fallback so
      existing tool registrations see no behaviour change. *)

open Alcotest
module Contract = Masc_mcp.Sdk_tool_contract

let schema_with_type t = `Assoc [ "type", `String t ]

let param_type_testable =
  let open Agent_sdk.Types in
  Alcotest.testable
    (fun fmt -> function
       | String -> Format.fprintf fmt "String"
       | Integer -> Format.fprintf fmt "Integer"
       | Number -> Format.fprintf fmt "Number"
       | Boolean -> Format.fprintf fmt "Boolean"
       | Array -> Format.fprintf fmt "Array"
       | Object -> Format.fprintf fmt "Object")
    ( = )
;;

let test_known_types_return_some () =
  let open Agent_sdk.Types in
  check
    (option param_type_testable)
    "string -> Some String"
    (Some String)
    (Contract.param_type_of_schema_opt (schema_with_type "string"));
  check
    (option param_type_testable)
    "integer -> Some Integer"
    (Some Integer)
    (Contract.param_type_of_schema_opt (schema_with_type "integer"));
  check
    (option param_type_testable)
    "number -> Some Number"
    (Some Number)
    (Contract.param_type_of_schema_opt (schema_with_type "number"));
  check
    (option param_type_testable)
    "boolean -> Some Boolean"
    (Some Boolean)
    (Contract.param_type_of_schema_opt (schema_with_type "boolean"));
  check
    (option param_type_testable)
    "array -> Some Array"
    (Some Array)
    (Contract.param_type_of_schema_opt (schema_with_type "array"));
  check
    (option param_type_testable)
    "object -> Some Object"
    (Some Object)
    (Contract.param_type_of_schema_opt (schema_with_type "object"))
;;

let test_unknown_types_return_none () =
  check
    (option param_type_testable)
    "null -> None"
    None
    (Contract.param_type_of_schema_opt (schema_with_type "null"));
  check
    (option param_type_testable)
    "typo'd type -> None"
    None
    (Contract.param_type_of_schema_opt (schema_with_type "strng"));
  check
    (option param_type_testable)
    "future JSON Schema 2020-12 type -> None"
    None
    (Contract.param_type_of_schema_opt (schema_with_type "tuple"))
;;

let test_wrapper_preserves_legacy_default () =
  (* Back-compat: unknown type still falls back to String (with a warn
     line going to the log). *)
  let open Agent_sdk.Types in
  check
    param_type_testable
    "unknown type -> String legacy"
    String
    (Contract.param_type_of_schema (schema_with_type "null"));
  check
    param_type_testable
    "known type unchanged"
    Integer
    (Contract.param_type_of_schema (schema_with_type "integer"))
;;

let test_no_type_field_falls_through_schema_type () =
  (* schema_type returns "object" when no "type" field but properties
     exist; "string" otherwise. The strict classifier should still hit
     a known branch for both cases (no warn). *)
  let open Agent_sdk.Types in
  check
    (option param_type_testable)
    "no type, no properties -> Some String"
    (Some String)
    (Contract.param_type_of_schema_opt (`Assoc []));
  let with_properties = `Assoc [ "properties", `Assoc [ "a", `Assoc [] ] ] in
  check
    (option param_type_testable)
    "no type, has properties -> Some Object"
    (Some Object)
    (Contract.param_type_of_schema_opt with_properties)
;;

let () =
  Alcotest.run
    "param_type_classifier"
    [ ( "strict classifier"
      , [ test_case
            "known JSON Schema types return Some"
            `Quick
            test_known_types_return_some
        ; test_case
            "unknown JSON Schema types return None"
            `Quick
            test_unknown_types_return_none
        ; test_case
            "no type field still resolves via schema_type"
            `Quick
            test_no_type_field_falls_through_schema_type
        ] )
    ; ( "back-compat wrapper"
      , [ test_case
            "wrapper preserves legacy String default"
            `Quick
            test_wrapper_preserves_legacy_default
        ] )
    ]
;;
