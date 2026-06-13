open Alcotest

module Under_test = Masc.Keeper_hooks_oas.For_testing

let test_empty_tool_args_are_explicit_object_shape () =
  check string "empty object shape" "object:0"
    (Under_test.tool_input_shape_for_log (`Assoc []));
  check string "empty object keys" "-"
    (Under_test.tool_input_keys_for_log (`Assoc []))

let test_tool_arg_shapes_keep_field_names () =
  let input =
    `Assoc
      [ "argv", `List [ `String "status"; `String "--short" ]
      ; "cwd", `String "repos/masc-mcp"
      ; "executable", `String "git"
      ]
  in
  check string "shape" "argv=array:2,cwd=string:14,executable=string:3"
    (Under_test.tool_input_shape_for_log input);
  check string "keys preserve input order" "argv,cwd,executable"
    (Under_test.tool_input_keys_for_log input)

let () =
  run "keeper_hooks_oas_log_shape"
    [ ( "tool-input-log-shape"
      , [ test_case "empty args are object:0" `Quick
            test_empty_tool_args_are_explicit_object_shape
        ; test_case "field shapes are explicit" `Quick
            test_tool_arg_shapes_keep_field_names
        ] )
    ]
