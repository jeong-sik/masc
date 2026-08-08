(** Unit tests for Tool_input_validation — deterministic schema checking. *)

open Agent_sdk
open Alcotest

let actual_to_string = function
  | Tool_input_validation.Missing -> "missing"
  | Tool_input_validation.Received description -> description
;;

let make_param ?(required = true) ~param_type name =
  { Types.name; description = ""; param_type; required }
;;

let make_schema parameters =
  Types.tool_schema_of_params ~name:"test_tool" ~description:"test" ~parameters ()
;;

(* ── Required field tests ──────────────────────────────── *)

let test_required_missing () =
  let schema = make_schema [ make_param ~param_type:Types.String "room" ] in
  let input = `Assoc [] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Invalid errors ->
    check int "one error" 1 (List.length errors);
    check string "path" "/room" (List.hd errors).path;
    check string "expected" "string" (List.hd errors).expected;
    check string "actual" "missing" (actual_to_string (List.hd errors).actual)
  | Tool_input_validation.Valid _ -> fail "expected Invalid for missing required field"
;;

let test_required_present () =
  let schema = make_schema [ make_param ~param_type:Types.String "room" ] in
  let input = `Assoc [ "room", `String "test-room" ] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Valid _ -> ()
  | Tool_input_validation.Invalid _ -> fail "expected Valid for present required field"
;;

let test_optional_missing () =
  let schema =
    make_schema [ make_param ~required:false ~param_type:Types.Integer "timeout" ]
  in
  let input = `Assoc [] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Valid _ -> ()
  | Tool_input_validation.Invalid _ -> fail "expected Valid for missing optional field"
;;

let test_null_is_type_error () =
  let schema = make_schema [ make_param ~param_type:Types.String "room" ] in
  let input = `Assoc [ "room", `Null ] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Invalid errors ->
    check int "one error" 1 (List.length errors);
    check string "actual" "null" (actual_to_string (List.hd errors).actual)
  | Tool_input_validation.Valid _ -> fail "expected Invalid for null required field"
;;

(* ── Type checking tests ──────────────────────────────── *)

let test_type_match_string () =
  let schema = make_schema [ make_param ~param_type:Types.String "msg" ] in
  let input = `Assoc [ "msg", `String "hello" ] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Valid _ -> ()
  | Tool_input_validation.Invalid _ -> fail "string should match String"
;;

let test_type_match_integer () =
  let schema = make_schema [ make_param ~param_type:Types.Integer "count" ] in
  let input = `Assoc [ "count", `Int 42 ] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Valid _ -> ()
  | Tool_input_validation.Invalid _ -> fail "int should match Integer"
;;

let test_type_mismatch () =
  let schema = make_schema [ make_param ~param_type:Types.Integer "count" ] in
  let input = `Assoc [ "count", `String "sixty" ] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Invalid errors ->
    check int "one error" 1 (List.length errors);
    check string "path" "/count" (List.hd errors).path;
    check string "expected" "integer" (List.hd errors).expected
  | Tool_input_validation.Valid _ -> fail "non-numeric string should not match Integer"
;;

let test_int_is_valid_number () =
  let schema = make_schema [ make_param ~param_type:Types.Number "value" ] in
  let input = `Assoc [ "value", `Int 42 ] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Valid _ -> ()
  | Tool_input_validation.Invalid _ -> fail "int should be valid Number"
;;

(* ── Strict input preservation tests ───────────────────── *)

let test_string_to_int_is_rejected_unchanged () =
  let schema = make_schema [ make_param ~param_type:Types.Integer "count" ] in
  let input = `Assoc [ "count", `String "42" ] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Invalid [ error ] ->
    check string "expected" "integer" error.expected;
    check string "actual" {|string("42")|} (actual_to_string error.actual);
    check string "input unchanged" {|{"count":"42"}|} (Yojson.Safe.to_string input)
  | Tool_input_validation.Invalid _ -> fail "expected one type error"
  | Tool_input_validation.Valid _ -> fail "string input must not be coerced"
;;

let test_string_to_bool_is_rejected () =
  let schema = make_schema [ make_param ~param_type:Types.Boolean "flag" ] in
  let input = `Assoc [ "flag", `String "true" ] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Invalid _ -> ()
  | Tool_input_validation.Valid _ -> fail "string input must not be coerced"
;;

let test_string_to_float_is_rejected () =
  let schema = make_schema [ make_param ~param_type:Types.Number "rate" ] in
  let input = `Assoc [ "rate", `String "3.14" ] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Invalid _ -> ()
  | Tool_input_validation.Valid _ -> fail "string input must not be coerced"
;;

let test_non_integral_float_to_integer_fails () =
  let schema = make_schema [ make_param ~param_type:Types.Integer "count" ] in
  let input = `Assoc [ "count", `Float 7.25 ] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Invalid errors ->
    check int "one error" 1 (List.length errors);
    check string "actual" "number(7.25)" (actual_to_string (List.hd errors).actual)
  | Tool_input_validation.Valid _ -> fail "expected non-integral float to fail"
;;

(* ── Edge cases ───────────────────────────────────────── *)

let test_empty_params () =
  let schema = make_schema [] in
  let input = `Assoc [ "anything", `String "goes" ] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Valid _ -> ()
  | Tool_input_validation.Invalid _ -> fail "empty params should accept anything"
;;

let test_null_input () =
  let schema = make_schema [] in
  let input = `Null in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Invalid [ error ] ->
    check string "expected" "object" error.expected;
    check string "actual" "null" (actual_to_string error.actual)
  | Tool_input_validation.Invalid _ -> fail "expected one root type error"
  | Tool_input_validation.Valid _ -> fail "null is not an object input"
;;

let test_multiple_errors () =
  let schema =
    make_schema
      [ make_param ~param_type:Types.String "room"
      ; make_param ~param_type:Types.Integer "timeout"
      ]
  in
  let input = `Assoc [] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Invalid errors -> check int "two errors" 2 (List.length errors)
  | Tool_input_validation.Valid _ ->
    fail "expected two errors for two missing required fields"
;;

let test_optional_null_is_type_error () =
  let schema =
    make_schema [ make_param ~required:false ~param_type:Types.Object "payload" ]
  in
  let input = `Assoc [ "payload", `Null ] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Invalid [ error ] ->
    check string "actual" "null" (actual_to_string error.actual)
  | Tool_input_validation.Invalid _ -> fail "expected one null type error"
  | Tool_input_validation.Valid _ -> fail "present null must match the declared type"
;;

let test_non_object_input_is_rejected_at_root () =
  let schema = make_schema [ make_param ~param_type:Types.String "room" ] in
  let input = `List [ `String "not"; `String "an object" ] in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Invalid errors ->
    check int "one error" 1 (List.length errors);
    check string "path" "/" (List.hd errors).path;
    check string "actual" "array" (actual_to_string (List.hd errors).actual)
  | Tool_input_validation.Valid _ -> fail "expected object input error"
;;

let test_actual_descriptions_cover_json_shapes () =
  let schema =
    make_schema
      [ make_param ~param_type:Types.Integer "bool_value"
      ; make_param ~param_type:Types.Boolean "float_value"
      ; make_param ~param_type:Types.Integer "long_string"
      ; make_param ~param_type:Types.Object "array_value"
      ; make_param ~param_type:Types.Array "object_value"
      ; make_param ~param_type:Types.Boolean "bad_intlit"
      ]
  in
  let input =
    `Assoc
      [ "bool_value", `Bool true
      ; "float_value", `Float 1.25
      ; "long_string", `String "abcdefghijklmnopqrstuvwxyz"
      ; "array_value", `List [ `Int 1 ]
      ; "object_value", `Assoc [ "k", `String "v" ]
      ; "bad_intlit", `Intlit "999999999999999999999999999999"
      ]
  in
  let actual_for path errors =
    errors
    |> List.find (fun (e : Tool_input_validation.field_error) -> e.path = path)
    |> fun e -> actual_to_string e.actual
  in
  match Tool_input_validation.validate schema input with
  | Tool_input_validation.Invalid errors ->
    check string "bool" "boolean(true)" (actual_for "/bool_value" errors);
    check string "float" "number(1.25)" (actual_for "/float_value" errors);
    check
      string
      "long string preview"
      {|string("abcdefghijklmnopqrst...")|}
      (actual_for "/long_string" errors);
    check string "array" "array" (actual_for "/array_value" errors);
    check string "object" "object" (actual_for "/object_value" errors);
    check
      string
      "intlit"
      "integer(999999999999999999999999999999)"
      (actual_for "/bad_intlit" errors);
    check int "six errors" 6 (List.length errors)
  | Tool_input_validation.Valid _ -> fail "expected shape description errors"
;;

(* ── format_errors tests ──────────────────────────────── *)

let test_format_errors () =
  let errors : Tool_input_validation.field_error list =
    [ { path = "/room"; expected = "required"; actual = Missing }
    ; { path = "/count"; expected = "integer"; actual = Received "string(\"sixty\")" }
    ]
  in
  let msg = Tool_input_validation.format_errors ~tool_name:"test_tool" errors in
  check bool "contains tool name" true (String.length msg > 0);
  check
    bool
    "contains /room"
    true
    (let re = Re.(compile (str "/room")) in
     Re.execp re msg);
  check
    bool
    "contains /count"
    true
    (let re = Re.(compile (str "/count")) in
     Re.execp re msg);
  check
    bool
    "contains fix instruction"
    true
    (let re = Re.(compile (str "Fix the parameters")) in
     Re.execp re msg)
;;

let test_format_errors_inline_missing () =
  let errors : Tool_input_validation.field_error list =
    [ { path = "/name"; expected = "string"; actual = Missing } ]
  in
  let args = `Assoc [ "op", `String "find"; "pattern", `String "*.ml" ] in
  let msg =
    Tool_input_validation.format_errors_inline ~tool_name:"read_file" ~args errors
  in
  check
    bool
    "contains tool name"
    true
    (let re = Re.(compile (str "read_file")) in
     Re.execp re msg);
  check
    bool
    "contains original JSON"
    true
    (let re = Re.(compile (str "find")) in
     Re.execp re msg);
  check
    bool
    "contains MISSING marker"
    true
    (let re = Re.(compile (str "MISSING")) in
     Re.execp re msg);
  check
    bool
    "contains actual type"
    true
    (let re = Re.(compile (str "string")) in
     Re.execp re msg);
  check
    bool
    "contains field name"
    true
    (let re = Re.(compile (str "\"name\"")) in
     Re.execp re msg)
;;

let test_format_errors_inline_type_error () =
  let errors : Tool_input_validation.field_error list =
    [ { path = "/count"; expected = "integer"; actual = Received "string(\"sixty\")" } ]
  in
  let args = `Assoc [ "count", `String "sixty" ] in
  let msg =
    Tool_input_validation.format_errors_inline ~tool_name:"test_tool" ~args errors
  in
  check
    bool
    "contains wrong type"
    true
    (let re = Re.(compile (str "wrong type")) in
     Re.execp re msg);
  check
    bool
    "contains expected"
    true
    (let re = Re.(compile (str "integer")) in
     Re.execp re msg);
  check
    bool
    "contains actual value"
    true
    (let re = Re.(compile (str "sixty")) in
     Re.execp re msg)
;;

let test_format_errors_inline_multiple () =
  let errors : Tool_input_validation.field_error list =
    [ { path = "/name"; expected = "string"; actual = Missing }
    ; { path = "/timeout"; expected = "number"; actual = Received "string(\"fast\")" }
    ]
  in
  let args = `Assoc [ "timeout", `String "fast" ] in
  let msg =
    Tool_input_validation.format_errors_inline ~tool_name:"test_tool" ~args errors
  in
  check
    bool
    "contains both errors"
    true
    (let re1 = Re.(compile (str "MISSING")) in
     let re2 = Re.(compile (str "wrong type")) in
     Re.execp re1 msg && Re.execp re2 msg)
;;

let test_format_errors_inline_path_without_slash () =
  let errors : Tool_input_validation.field_error list =
    [ { path = "raw"; expected = "object"; actual = Received "array" } ]
  in
  let msg =
    Tool_input_validation.format_errors_inline
      ~tool_name:"test_tool"
      ~args:(`List [])
      errors
  in
  check
    bool
    "uses raw path as field name"
    true
    (let re = Re.(compile (str "\"raw\": wrong type")) in
     Re.execp re msg)
;;

(* ── Test runner ──────────────────────────────────────── *)

let () =
  run
    "tool_input_validation"
    [ ( "required"
      , [ test_case "missing required" `Quick test_required_missing
        ; test_case "present required" `Quick test_required_present
        ; test_case "optional missing" `Quick test_optional_missing
        ; test_case "null is type error" `Quick test_null_is_type_error
        ] )
    ; ( "type_check"
      , [ test_case "string matches String" `Quick test_type_match_string
        ; test_case "int matches Integer" `Quick test_type_match_integer
        ; test_case "type mismatch" `Quick test_type_mismatch
        ; test_case "int is valid Number" `Quick test_int_is_valid_number
        ] )
    ; ( "strict_preservation"
      , [ test_case
            "string to int rejects"
            `Quick
            test_string_to_int_is_rejected_unchanged
        ; test_case "string to bool rejects" `Quick test_string_to_bool_is_rejected
        ; test_case "string to float rejects" `Quick test_string_to_float_is_rejected
        ; test_case
            "non-integral float to integer fails"
            `Quick
            test_non_integral_float_to_integer_fails
        ] )
    ; ( "edge_cases"
      , [ test_case "empty params" `Quick test_empty_params
        ; test_case "null input" `Quick test_null_input
        ; test_case "multiple errors" `Quick test_multiple_errors
        ; test_case "optional null is type error" `Quick test_optional_null_is_type_error
        ; test_case "non-object input" `Quick test_non_object_input_is_rejected_at_root
        ; test_case
            "actual descriptions"
            `Quick
            test_actual_descriptions_cover_json_shapes
        ] )
    ; ( "format"
      , [ test_case "format_errors output" `Quick test_format_errors
        ; test_case "inline: missing field" `Quick test_format_errors_inline_missing
        ; test_case "inline: type error" `Quick test_format_errors_inline_type_error
        ; test_case "inline: multiple errors" `Quick test_format_errors_inline_multiple
        ; test_case
            "inline: path without slash"
            `Quick
            test_format_errors_inline_path_without_slash
        ] )
    ]
;;
