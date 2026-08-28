open Alcotest

module Contract = Masc.Keeper_json_schema_value_contract
module Descriptor = Masc.Keeper_tool_descriptor

let rec collect_schema acc = function
  | `Assoc fields ->
    List.fold_left
      (fun acc (keyword, value) ->
         let acc = keyword :: acc in
         match keyword, value with
         | "properties", `Assoc properties ->
           List.fold_left (fun acc (_, schema) -> collect_schema acc schema) acc properties
         | ("items" | "not"), schema -> collect_schema acc schema
         | ("oneOf" | "anyOf"), `List schemas -> List.fold_left collect_schema acc schemas
         | "additionalProperties", (`Assoc _ as schema) -> collect_schema acc schema
         | _ -> acc)
      acc fields
  | _ -> acc

let descriptor_keywords () =
  Descriptor.all_descriptors ()
  |> List.fold_left (fun acc descriptor -> collect_schema acc descriptor.Descriptor.input_schema) []
  |> List.sort_uniq String.compare

let test_current_descriptor_vocabulary_is_closed () =
  check (list string) "exact input-schema keywords"
    [ "additionalProperties"; "anyOf"; "default"; "description"; "enum"
    ; "exclusiveMinimum"; "items"; "maxItems"; "maxLength"; "maxProperties"
    ; "maximum"; "minItems"; "minLength"; "minProperties"; "minimum"; "not"
    ; "oneOf"; "pattern"; "properties"; "required"; "type"
    ]
    (descriptor_keywords ());
  Descriptor.all_descriptors ()
  |> List.iter (fun descriptor ->
    match Contract.validate_schema descriptor.Descriptor.input_schema with
    | Ok () -> ()
    | Error error ->
      failf "descriptor %s schema unsupported: %s"
        descriptor.id (Yojson.Safe.to_string (Contract.error_to_json error)))

let accept schema value =
  match Contract.validate ~schema value with
  | Ok () -> ()
  | Error error -> fail (Yojson.Safe.to_string (Contract.error_to_json error))

let reject keyword schema value =
  match Contract.validate ~schema value with
  | Error (Contract.Value_mismatch { keyword = actual; _ }) -> check string "keyword" keyword actual
  | Error error -> fail ("wrong error: " ^ Yojson.Safe.to_string (Contract.error_to_json error))
  | Ok () -> fail ("accepted mismatch for " ^ keyword)

let test_types_enum_and_scalar_constraints () =
  let nullable = `Assoc [ "type", `List [ `String "string"; `String "null" ] ] in
  accept nullable (`String "ok"); accept nullable `Null; reject "type" nullable (`Int 1);
  let enum = `Assoc [ "type", `String "string"; "enum", `List [ `String "a"; `String "b" ] ] in
  accept enum (`String "a"); reject "enum" enum (`String "c");
  accept (`Assoc [ "enum", `List [ `Int 1 ] ]) (`Float 1.0);
  (match Contract.validate_schema (`Assoc [ "enum", `List [ `Int 1; `Float 1.0 ] ]) with
   | Error (Contract.Invalid_schema { keyword = "enum"; _ }) -> ()
   | _ -> fail "mathematically duplicate enum numbers were accepted");
  let string_schema =
    `Assoc [ "type", `String "string"; "minLength", `Int 2; "maxLength", `Int 3
           ; "pattern", `String "^[가-힣]+$" ]
  in
  accept string_schema (`String "가나"); reject "minLength" string_schema (`String "가");
  reject "pattern" string_schema (`String "ab");
  let number = `Assoc [ "type", `String "number"; "exclusiveMinimum", `Int 1; "maximum", `Int 3 ] in
  accept number (`Int 2); reject "exclusiveMinimum" number (`Int 1); reject "maximum" number (`Int 4)

let test_nested_objects_arrays_and_additional_schema () =
  let item =
    `Assoc [ "type", `String "object"; "properties", `Assoc [ "id", `Assoc [ "type", `String "integer" ] ]
           ; "required", `List [ `String "id" ]; "additionalProperties", `Assoc [ "type", `String "string" ]
           ; "minProperties", `Int 1; "maxProperties", `Int 2 ]
  in
  let schema = `Assoc [ "type", `String "array"; "items", item; "minItems", `Int 1; "maxItems", `Int 2 ] in
  accept schema (`List [ `Assoc [ "id", `Int 1; "note", `String "ok" ] ]);
  reject "required" schema (`List [ `Assoc [] ]);
  let wrong_nested = `List [ `Assoc [ "id", `String "wrong" ] ] in
  (match Contract.validate ~schema wrong_nested with
   | Error (Contract.Value_mismatch { path = [ "0"; "id" ]; keyword = "type"; _ }) -> ()
   | _ -> fail "nested mismatch lost its structured path");
  reject "maxProperties" schema (`List [ `Assoc [ "id", `Int 1; "a", `String "a"; "b", `String "b" ] ]);
  reject "minItems" schema (`List []);
  reject "additionalProperties"
    (`Assoc [ "type", `String "object"; "additionalProperties", `Bool false ])
    (`Assoc [ "extra", `String "no" ])

let test_logical_keywords () =
  let string = `Assoc [ "type", `String "string" ] in
  let integer = `Assoc [ "type", `String "integer" ] in
  let one_of = `Assoc [ "oneOf", `List [ string; integer ] ] in
  accept one_of (`String "x"); reject "oneOf" one_of (`Bool true);
  reject "oneOf"
    (`Assoc [ "oneOf", `List [ integer; `Assoc [ "type", `String "number" ] ] ])
    (`Int 1);
  reject "oneOf"
    (`Assoc [ "oneOf", `List [ `Assoc [ "const", `Int 1 ]; `Assoc [ "const", `Float 1.0 ] ] ])
    (`Int 1);
  let any_of = `Assoc [ "anyOf", `List [ string; integer ] ] in
  accept any_of (`Int 1); reject "anyOf" any_of (`Bool true);
  let not_string = `Assoc [ "not", string ] in
  accept not_string (`Int 1); reject "not" not_string (`String "x");
  accept
    (`Assoc [ "type", `String "string"; "description", `String "annotation"
            ; "default", `String "ignored" ])
    (`String "actual")

let test_arbitrary_precision_integer_bounds () =
  let bound = `Intlit "99999999999999999999999999999999999999" in
  let below = `Intlit "99999999999999999999999999999999999998" in
  let above = `Intlit "100000000000000000000000000000000000000" in
  let minimum = `Assoc [ "type", `String "integer"; "minimum", bound ] in
  accept minimum bound; accept minimum above; reject "minimum" minimum below;
  let exact = `Assoc [ "const", bound ] in
  accept exact bound; reject "const" exact above

let test_schema_errors_and_json_codec () =
  (match Contract.validate_schema (`Assoc [ "invented", `Bool true ]) with
   | Error (Contract.Unsupported_schema detail) -> check string "unsupported keyword" "invented" detail.keyword
   | _ -> fail "unknown keyword was not typed Unsupported_schema");
  List.iter
    (fun schema ->
       match Contract.validate_schema schema with
       | Error (Contract.Invalid_schema _) -> ()
       | _ -> fail "malformed schema was accepted")
    [ `Assoc [ "type", `String "invented" ]; `Assoc [ "items", `String "not-a-schema" ]
    ; `Assoc [ "pattern", `String "[" ]; `Assoc [ "oneOf", `List [] ] ];
  let error =
    match Contract.validate ~schema:(`Assoc [ "type", `String "string" ]) (`Int 1) with
    | Error error -> error | Ok () -> fail "type mismatch accepted"
  in
  let open Yojson.Safe.Util in
  let json = Contract.error_to_json error in
  check string "codec kind" "value_mismatch" (json |> member "kind" |> to_string);
  check string "codec keyword" "type" (json |> member "keyword" |> to_string)

let test_runtime_enum_ownership_is_unchanged () =
  let descriptor =
    Descriptor.all_descriptors ()
    |> List.find (fun descriptor -> String.equal descriptor.Descriptor.internal_name "masc_goal_list")
  in
  let args = `Assoc [ "phase", `String "notaphase" ] in
  reject "enum" descriptor.input_schema args;
  match Masc.Tool_input_validation.validate_args ~schema:descriptor.input_schema ~name:"masc_goal_list" ~args () with
  | Ok forwarded -> check bool "runtime forwards unchanged" true (Yojson.Safe.equal args forwarded)
  | Error _ -> fail "opt-in contract changed runtime enum ownership"

let () =
  Eio_main.run @@ fun _ ->
  run "keeper_json_schema_value_contract"
    [ "schema", [ test_case "current descriptor vocabulary" `Quick test_current_descriptor_vocabulary_is_closed
                  ; test_case "malformed and unsupported" `Quick test_schema_errors_and_json_codec ]
    ; "values", [ test_case "types enum scalar constraints" `Quick test_types_enum_and_scalar_constraints
                  ; test_case "nested object array" `Quick test_nested_objects_arrays_and_additional_schema
                  ; test_case "logical keywords" `Quick test_logical_keywords
                  ; test_case "arbitrary precision integer bounds" `Quick test_arbitrary_precision_integer_bounds
                  ; test_case "runtime enum ownership" `Quick test_runtime_enum_ownership_is_unchanged ] ]
