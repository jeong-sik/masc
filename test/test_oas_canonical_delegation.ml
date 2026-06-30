open Alcotest

let check_calls ~file ~callee ~expected =
  check int
    (Printf.sprintf "%s calls %s" file callee)
    expected
    (Ast_grep.count_calls ~module_path:file ~callee)
;;

let check_no_binding ~file ~name =
  check int
    (Printf.sprintf "%s does not define %s" file name)
    0
    (Ast_grep.count_value_bindings ~module_path:file ~name)
;;

let test_masc_delegates_canonical_oas_projections () =
  check_calls
    ~file:"lib/context_compact_oas.ml"
    ~callee:"Agent_sdk.Types.role_to_string"
    ~expected:1;
  check_calls
    ~file:"lib/keeper/keeper_event_bridge_error_json.ml"
    ~callee:"Agent_sdk.Types.total_tokens"
    ~expected:1;
  check_calls
    ~file:"lib/keeper/keeper_run_tools_setup.ml"
    ~callee:"Agent_sdk.Types.params_to_input_schema"
    ~expected:1;
  check_calls
    ~file:"lib/sdk_tool_contract.ml"
    ~callee:"Agent_sdk.Types.param_type_of_string"
    ~expected:1
;;

let test_hand_rolled_tool_schema_projection_is_not_reintroduced () =
  check_no_binding ~file:"lib/keeper/keeper_run_tools_setup.ml" ~name:"param_type_str";
  check_calls
    ~file:"lib/keeper/keeper_run_tools_setup.ml"
    ~callee:"Agent_sdk.Types.param_type_to_string"
    ~expected:0
;;

let () =
  Alcotest.run
    "oas-canonical-delegation"
    [ ( "delegation"
      , [ test_case
            "MASC delegates canonical projections to OAS"
            `Quick
            test_masc_delegates_canonical_oas_projections
        ; test_case
            "tool schema projection helper is not hand-rolled locally"
            `Quick
            test_hand_rolled_tool_schema_projection_is_not_reintroduced
        ] )
    ]
;;
