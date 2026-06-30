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
    ~file:"lib/keeper/keeper_context_core_message_json.ml"
    ~callee:"Agent_sdk.Types.role_to_string"
    ~expected:1;
  check_calls
    ~file:"lib/keeper/keeper_context_core_message_json.ml"
    ~callee:"Agent_sdk.Types.role_of_string"
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

let test_masc_delegates_oas_stream_progress_predicates () =
  check_calls
    ~file:"lib/keeper/keeper_chat_oas_stream_bridge.ml"
    ~callee:
      "Agent_sdk.Llm_provider.Streaming.sse_event_is_deliverable_progress_signal"
    ~expected:1
;;

let test_masc_delegates_oas_response_shape_metrics () =
  let file = "lib/keeper/keeper_hooks_oas_response_metrics.ml" in
  check_calls ~file ~callee:"Response_shape.summarize" ~expected:1;
  check_calls ~file ~callee:"Response_shape.has_deliverable_content" ~expected:1;
  check_calls ~file ~callee:"Response_shape.content_shape" ~expected:1;
  check_calls ~file ~callee:"Response_shape.content_shape_to_string" ~expected:1
;;

let test_masc_delegates_oas_tool_call_projection () =
  check_calls
    ~file:"lib/keeper/keeper_context_tool_message_pairs.ml"
    ~callee:"Canonical_tool.tool_call_of_block"
    ~expected:2;
  check_calls
    ~file:"lib/keeper/keeper_context_core_accessors.ml"
    ~callee:"Canonical_tool.tool_call_of_block"
    ~expected:1;
  check_calls
    ~file:"lib/keeper/keeper_agent_prompt_metrics.ml"
    ~callee:"Canonical_tool.tool_call_of_block"
    ~expected:2;
  check_calls
    ~file:"lib/keeper/keeper_librarian.ml"
    ~callee:"Canonical_tool.tool_call_of_block"
    ~expected:1;
  check_calls
    ~file:"lib/keeper/keeper_wake_telemetry.ml"
    ~callee:"Canonical_tool.tool_call_of_block"
    ~expected:1
;;

let test_masc_delegates_oas_reasoning_details_projection () =
  check_calls
    ~file:"lib/keeper/keeper_chat_oas_stream_bridge.ml"
    ~callee:"Agent_sdk.Types.reasoning_details_text"
    ~expected:1;
  check_calls
    ~file:"lib/keeper/keeper_context_core.ml"
    ~callee:"Agent_sdk.Types.reasoning_details_text"
    ~expected:1;
  check_calls
    ~file:"lib/keeper/keeper_wake_telemetry.ml"
    ~callee:"Agent_sdk.Types.reasoning_details_text"
    ~expected:1;
  check_calls
    ~file:"lib/keeper/keeper_agent_run_thinking_trajectory.ml"
    ~callee:"Agent_sdk.Types.reasoning_details_text"
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
            "MASC delegates stream progress classification to OAS"
            `Quick
            test_masc_delegates_oas_stream_progress_predicates
        ; test_case
            "MASC delegates response shape metrics to OAS"
            `Quick
            test_masc_delegates_oas_response_shape_metrics
        ; test_case
            "MASC delegates tool-call block projection to OAS"
            `Quick
            test_masc_delegates_oas_tool_call_projection
        ; test_case
            "MASC delegates reasoning-details projection to OAS"
            `Quick
            test_masc_delegates_oas_reasoning_details_projection
        ; test_case
            "tool schema projection helper is not hand-rolled locally"
            `Quick
            test_hand_rolled_tool_schema_projection_is_not_reintroduced
        ] )
    ]
;;
