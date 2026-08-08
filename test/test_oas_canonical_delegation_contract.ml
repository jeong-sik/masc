(** Agent core canonical-delegation boundary contract.

    MASC sites delegate to [Agent_sdk] canonical projections:
    - [keeper_event_bridge_error_json]: [total_tokens]
    - [context_compact_oas]: [role_to_string]
    - [keeper_run_tools_setup]: [params_to_input_schema]
    - keeper prompt/telemetry consumers: [Canonical_tool.tool_call_of_block]

    These tests execute both the canonical helper and the MASC projection that
    reaches production consumers. *)

open Alcotest

(* Billable total excludes cache tokens. *)
let test_total_tokens () =
  let usage : Agent_sdk.Types.api_usage =
    { input_tokens = 30
    ; output_tokens = 12
    ; cache_creation_input_tokens = 7
    ; cache_read_input_tokens = 5
    ; cost_usd = None
    }
  in
  check int "billable = input + output (cache excluded)" 42
    (Agent_sdk.Types.total_tokens usage)

(* Every role variant maps to its canonical wire string. *)
let test_role_to_string () =
  check string "system" "system" (Agent_sdk.Types.role_to_string Agent_sdk.Types.System);
  check string "user" "user" (Agent_sdk.Types.role_to_string Agent_sdk.Types.User);
  check string "assistant" "assistant"
    (Agent_sdk.Types.role_to_string Agent_sdk.Types.Assistant);
  check string "tool" "tool" (Agent_sdk.Types.role_to_string Agent_sdk.Types.Tool)

(* Input schema shape keeps ordered properties, {type; description} per param,
   and the exact required-name set. *)
let test_params_to_input_schema_shape () =
  let params : Agent_sdk.Types.tool_param list =
    [ { name = "path"; description = "file path"; param_type = Agent_sdk.Types.String; required = true }
    ; { name = "limit"; description = "max rows"; param_type = Agent_sdk.Types.Integer; required = false }
    ]
  in
  let expected =
    `Assoc
      [ "type", `String "object"
      ; ( "properties"
        , `Assoc
            [ "path", `Assoc [ "type", `String "string"; "description", `String "file path" ]
            ; "limit", `Assoc [ "type", `String "integer"; "description", `String "max rows" ]
            ] )
      ; "required", `List [ `String "path" ]
      ]
  in
  check bool "params_to_input_schema matches hand-rolled shape" true
    (Agent_sdk.Types.params_to_input_schema params = expected)

let test_tool_call_of_block_shape () =
  let input = `Assoc [ "path", `String "lib/" ] in
  let block = Agent_sdk.Types.ToolUse { id = "call_read"; name = "read"; input } in
  match Agent_sdk.Canonical_tool.tool_call_of_block block with
  | Some call ->
      check string "call_id" "call_read" call.Agent_sdk.Canonical_tool.call_id;
      check string "name" "read" call.Agent_sdk.Canonical_tool.name;
      check bool "input preserved" true (call.Agent_sdk.Canonical_tool.input = input)
  | None -> fail "ToolUse block must project to a canonical tool call"

let sample_response () : Agent_sdk.Types.api_response =
  { id = "response-1"
  ; model = "test-model"
  ; stop_reason = Agent_sdk.Types.EndTurn
  ; content = [ Agent_sdk.Types.Text "visible"; Agent_sdk.Types.Thinking "hidden" ]
  ; usage =
      Some
        { input_tokens = 30
        ; output_tokens = 12
        ; cache_creation_input_tokens = 7
        ; cache_read_input_tokens = 5
        ; cost_usd = None
        }
  ; telemetry = None
  }

let test_masc_response_projections_delegate () =
  let response = sample_response () in
  let expected_usage =
    match response.usage with
    | Some usage -> usage
    | None -> fail "sample response must include usage"
  in
  check string "Fusion visible text" (Agent_sdk.Types.visible_text_of_response response)
    (Fusion_oas.answer_text response);
  check bool "Keeper usage projection" true
    (Inference_utils.usage_of_response response = expected_usage)

let test_masc_error_projection_delegates () =
  let error = Agent_sdk.Error.Internal "probe" in
  let projection = Keeper_event_bridge_error_json.agent_failed_error_projection error in
  check string "canonical error category"
    Agent_sdk.Error.(category error |> category_label)
    projection.error_domain

let suite =
  [ test_case "total_tokens billable" `Quick test_total_tokens
  ; test_case "role_to_string variants" `Quick test_role_to_string
  ; test_case "params_to_input_schema shape" `Quick test_params_to_input_schema_shape
  ; test_case "tool_call_of_block shape" `Quick test_tool_call_of_block_shape
  ; test_case "MASC response projections delegate" `Quick
      test_masc_response_projections_delegate
  ; test_case "MASC error projection delegates" `Quick
      test_masc_error_projection_delegates
  ]

let () = run "oas_canonical_delegation_contract" [ "contract", suite ]
