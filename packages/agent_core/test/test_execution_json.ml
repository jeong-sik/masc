open Agent_core

let check_error expected_context expected_path expected_reason = function
  | Error { Execution_json.context; path; reason }
    when String.equal context expected_context
         && path = expected_path
         && reason = expected_reason -> ()
  | Error error ->
    Alcotest.fail
      ("unexpected JSON validation error: "
       ^ Execution_json.validation_error_to_string error)
  | Ok () -> Alcotest.fail "invalid JSON was accepted"
;;

let test_duplicate_path () =
  let json =
    `Assoc
      [ ( "outer"
        , `List [ `Null; `Assoc [ "same", `Int 1; "same", `Int 2 ] ] )
      ]
  in
  Execution_json.validate ~context:"fixture" json
  |> check_error
       "fixture"
       [ Execution_json.Object_field "outer"
       ; Execution_json.Array_index 1
       ; Execution_json.Object_field "same"
       ]
       Execution_json.Duplicate_object_key
;;

let test_non_finite_path () =
  Execution_json.validate
    ~context:"fixture"
    (`Assoc [ "outer", `List [ `Float Float.nan ] ])
  |> check_error
       "fixture"
       [ Execution_json.Object_field "outer"; Execution_json.Array_index 0 ]
       Execution_json.Non_finite_float
;;

let test_invalid_integer_literal_path () =
  Execution_json.validate
    ~context:"fixture"
    (`Assoc [ "outer", `Intlit "not-an-integer" ])
  |> check_error
       "fixture"
       [ Execution_json.Object_field "outer" ]
       (Execution_json.Invalid_integer_literal "not-an-integer")
;;

let test_nested_standard_json () =
  match
    Execution_json.validate
      ~context:"fixture"
      (`Assoc
         [ "outer", `List [ `Null; `Assoc [ "left", `Int 1; "right", `Float 2.0 ] ]
         ])
  with
  | Ok () -> ()
  | Error error ->
    Alcotest.fail
      ("valid JSON was rejected: " ^ Execution_json.validation_error_to_string error)
;;

let () =
  Alcotest.run
    "Execution_json"
    [ ( "canonical"
      , [ Alcotest.test_case "duplicate path" `Quick test_duplicate_path
        ; Alcotest.test_case "non-finite path" `Quick test_non_finite_path
        ; Alcotest.test_case
            "invalid integer literal path"
            `Quick
            test_invalid_integer_literal_path
        ; Alcotest.test_case "nested standard JSON" `Quick test_nested_standard_json
        ] )
    ]
;;
