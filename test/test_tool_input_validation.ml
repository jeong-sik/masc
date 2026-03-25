(** Unit tests for Tool_input_validation — pre-dispatch schema validation. *)

open Masc_mcp

(** Simple substring check — avoids Astring dependency. *)
let string_contains haystack needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen > hlen then false
  else
    let found = ref false in
    for i = 0 to hlen - nlen do
      if not !found && String.sub haystack i nlen = needle then found := true
    done;
    !found

(* ================================================================ *)
(* Helper: build a simple tool schema                                *)
(* ================================================================ *)

(** Build a JSON Schema object with given properties and required list. *)
let make_schema ?(required = []) (props : (string * string) list) : Yojson.Safe.t =
  let prop_entries =
    List.map (fun (name, type_str) ->
      (name, `Assoc [("type", `String type_str)])
    ) props
  in
  `Assoc [
    ("type", `String "object");
    ("properties", `Assoc prop_entries);
    ("required", `List (List.map (fun s -> `String s) required));
  ]

(* ================================================================ *)
(* Test: required field validation                                   *)
(* ================================================================ *)

let test_required_present () =
  let schema = make_schema ~required:["name"] [("name", "string")] in
  let args = `Assoc [("name", `String "alice")] in
  match Tool_input_validation.validate ~tool_name:"test" ~schema ~args with
  | Ok () -> ()
  | Error msg -> Alcotest.fail (Printf.sprintf "Expected Ok, got Error: %s" msg)

let test_required_missing () =
  let schema = make_schema ~required:["name"; "room"] [("name", "string"); ("room", "string")] in
  let args = `Assoc [("name", `String "alice")] in
  match Tool_input_validation.validate ~tool_name:"test" ~schema ~args with
  | Error msg ->
    Alcotest.(check bool) "mentions room" true (String.length msg > 0 && string_contains msg "room")
  | Ok () -> Alcotest.fail "Expected Error for missing required field"

let test_required_missing_multiple () =
  let schema = make_schema ~required:["a"; "b"; "c"] [("a", "string"); ("b", "string"); ("c", "string")] in
  let args = `Assoc [("a", `String "ok")] in
  match Tool_input_validation.validate ~tool_name:"test" ~schema ~args with
  | Error msg ->
    Alcotest.(check bool) "mentions b" true (string_contains msg "b");
    Alcotest.(check bool) "mentions c" true (string_contains msg "c")
  | Ok () -> Alcotest.fail "Expected Error for missing multiple fields"

let test_no_required_fields () =
  let schema = make_schema [("name", "string")] in
  let args = `Assoc [] in
  match Tool_input_validation.validate ~tool_name:"test" ~schema ~args with
  | Ok () -> ()
  | Error msg -> Alcotest.fail (Printf.sprintf "Expected Ok, got Error: %s" msg)

(* ================================================================ *)
(* Test: type validation                                             *)
(* ================================================================ *)

let test_type_string_ok () =
  let schema = make_schema [("name", "string")] in
  let args = `Assoc [("name", `String "alice")] in
  match Tool_input_validation.validate ~tool_name:"test" ~schema ~args with
  | Ok () -> ()
  | Error msg -> Alcotest.fail msg

let test_type_string_wrong () =
  let schema = make_schema [("name", "string")] in
  let args = `Assoc [("name", `Int 42)] in
  match Tool_input_validation.validate ~tool_name:"test" ~schema ~args with
  | Error msg ->
    Alcotest.(check bool) "mentions type mismatch" true
      (string_contains msg "expected string")
  | Ok () -> Alcotest.fail "Expected type error"

let test_type_integer_ok () =
  let schema = make_schema [("count", "integer")] in
  let args = `Assoc [("count", `Int 5)] in
  match Tool_input_validation.validate ~tool_name:"test" ~schema ~args with
  | Ok () -> ()
  | Error msg -> Alcotest.fail msg

let test_type_boolean_wrong () =
  let schema = make_schema [("flag", "boolean")] in
  let args = `Assoc [("flag", `String "true")] in
  match Tool_input_validation.validate ~tool_name:"test" ~schema ~args with
  | Error msg ->
    Alcotest.(check bool) "mentions boolean" true
      (string_contains msg "expected boolean")
  | Ok () -> Alcotest.fail "Expected type error"

let test_type_array_ok () =
  let schema = make_schema [("items", "array")] in
  let args = `Assoc [("items", `List [`String "a"; `String "b"])] in
  match Tool_input_validation.validate ~tool_name:"test" ~schema ~args with
  | Ok () -> ()
  | Error msg -> Alcotest.fail msg

let test_number_accepts_int () =
  let schema = make_schema [("value", "number")] in
  let args = `Assoc [("value", `Int 42)] in
  match Tool_input_validation.validate ~tool_name:"test" ~schema ~args with
  | Ok () -> ()
  | Error msg -> Alcotest.fail msg

(* ================================================================ *)
(* Test: edge cases                                                  *)
(* ================================================================ *)

let test_null_args_no_required () =
  let schema = make_schema [("optional", "string")] in
  let args = `Null in
  match Tool_input_validation.validate ~tool_name:"test" ~schema ~args with
  | Ok () -> ()
  | Error msg -> Alcotest.fail msg

let test_null_args_with_required () =
  let schema = make_schema ~required:["name"] [("name", "string")] in
  let args = `Null in
  match Tool_input_validation.validate ~tool_name:"test" ~schema ~args with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "Expected error for null args with required fields"

let test_extra_fields_allowed () =
  let schema = make_schema ~required:["name"] [("name", "string")] in
  let args = `Assoc [("name", `String "alice"); ("extra", `Int 42)] in
  match Tool_input_validation.validate ~tool_name:"test" ~schema ~args with
  | Ok () -> ()
  | Error msg -> Alcotest.fail msg

let test_non_object_schema_skipped () =
  let schema = `Assoc [("type", `String "string")] in
  let args = `String "anything" in
  match Tool_input_validation.validate ~tool_name:"test" ~schema ~args with
  | Ok () -> ()
  | Error msg -> Alcotest.fail msg

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run "Tool_input_validation" [
    ("required", [
      Alcotest.test_case "present" `Quick test_required_present;
      Alcotest.test_case "missing" `Quick test_required_missing;
      Alcotest.test_case "missing multiple" `Quick test_required_missing_multiple;
      Alcotest.test_case "no required fields" `Quick test_no_required_fields;
    ]);
    ("type_check", [
      Alcotest.test_case "string ok" `Quick test_type_string_ok;
      Alcotest.test_case "string wrong" `Quick test_type_string_wrong;
      Alcotest.test_case "integer ok" `Quick test_type_integer_ok;
      Alcotest.test_case "boolean wrong" `Quick test_type_boolean_wrong;
      Alcotest.test_case "array ok" `Quick test_type_array_ok;
      Alcotest.test_case "number accepts int" `Quick test_number_accepts_int;
    ]);
    ("edge_cases", [
      Alcotest.test_case "null args no required" `Quick test_null_args_no_required;
      Alcotest.test_case "null args with required" `Quick test_null_args_with_required;
      Alcotest.test_case "extra fields allowed" `Quick test_extra_fields_allowed;
      Alcotest.test_case "non-object schema skipped" `Quick test_non_object_schema_skipped;
    ]);
  ]
