(* Test param_type_of_schema_opt (strict) and param_type_of_schema
   (back-compat with warn). Fixes #8832. *)

open Alcotest

module Sdk = Masc_mcp.Sdk_tool_contract
module Types = Agent_sdk.Types

let param_type_testable =
  let pp fmt t =
    let s =
      match t with
      | Types.String -> "String"
      | Types.Integer -> "Integer"
      | Types.Number -> "Number"
      | Types.Boolean -> "Boolean"
      | Types.Array -> "Array"
      | Types.Object -> "Object"
    in
    Format.fprintf fmt "%s" s
  in
  testable pp ( = )

(* Build a minimal JSON Schema with the given "type" field. *)
let schema_with_type wire : Yojson.Safe.t =
  `Assoc [ ("type", `String wire) ]

let test_known_wire_types_return_some () =
  let cases =
    [ ("string", Types.String)
    ; ("integer", Types.Integer)
    ; ("number", Types.Number)
    ; ("boolean", Types.Boolean)
    ; ("array", Types.Array)
    ; ("object", Types.Object)
    ]
  in
  List.iter
    (fun (wire, expected) ->
      match Sdk.param_type_of_schema_opt (schema_with_type wire) with
      | Some actual ->
          check param_type_testable
            (Printf.sprintf "wire %S -> Some" wire)
            expected actual
      | None -> failf "wire %S: expected Some, got None" wire)
    cases

let test_unknown_wire_types_return_none () =
  let unknown_wires = [ "null"; ""; "union"; "Number" (* case-sensitive *); "int32"; "foo" ] in
  List.iter
    (fun wire ->
      match Sdk.param_type_of_schema_opt (schema_with_type wire) with
      | None -> ()
      | Some actual ->
          failf "wire %S: expected None, got Some %s" wire
            (Format.asprintf "%a" (Fmt.of_to_string (fun t ->
               match t with
               | Types.String -> "String"
               | Types.Integer -> "Integer"
               | Types.Number -> "Number"
               | Types.Boolean -> "Boolean"
               | Types.Array -> "Array"
               | Types.Object -> "Object"))
               actual))
    unknown_wires

let test_back_compat_wrapper_returns_string_for_unknown () =
  (* The back-compat wrapper falls back to String for unknown wire types
     so existing callers continue to receive the legacy classification.
     The log.warn side effect is not asserted here; see runtime logs. *)
  let cases = [ "null"; ""; "foo"; "union" ] in
  List.iter
    (fun wire ->
      check param_type_testable
        (Printf.sprintf "wire %S -> String (back-compat)" wire)
        Types.String
        (Sdk.param_type_of_schema (schema_with_type wire)))
    cases

let test_back_compat_wrapper_preserves_known () =
  (* Known wire types must pass through unchanged. *)
  check param_type_testable "string -> String" Types.String
    (Sdk.param_type_of_schema (schema_with_type "string"));
  check param_type_testable "integer -> Integer" Types.Integer
    (Sdk.param_type_of_schema (schema_with_type "integer"));
  check param_type_testable "boolean -> Boolean" Types.Boolean
    (Sdk.param_type_of_schema (schema_with_type "boolean"))

let () =
  run "param_type_of_schema"
    [ ( "strict_classifier_opt"
      , [ test_case "known wire types -> Some" `Quick test_known_wire_types_return_some
        ; test_case "unknown wire types -> None" `Quick test_unknown_wire_types_return_none
        ] )
    ; ( "back_compat_wrapper"
      , [ test_case "unknown wire -> String fallback" `Quick
            test_back_compat_wrapper_returns_string_for_unknown
        ; test_case "known wire passthrough" `Quick
            test_back_compat_wrapper_preserves_known
        ] )
    ]
