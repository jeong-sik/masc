(** OAS canonical-delegation boundary contract (masc#22809).

    Four MASC sites delegate to OAS [Agent_sdk.Types] canonical projections
    instead of hand-rolling them:
    - [keeper_event_bridge_error_json]: [total_tokens]
    - [context_compact_oas]: [role_to_string]
    - [sdk_tool_contract]: [param_type_of_string] (strict [None] on unknown)
    - [keeper_run_tools_setup]: [params_to_input_schema]

    These tests pin the exact OAS outputs MASC now emits on the wire (provider
    request tool schema, dashboard role labels, usage JSON). They are a boundary
    regression guard: if an OAS release changes any of these canonical outputs,
    the change surfaces here loudly instead of drifting MASC's emitted wire
    silently. They also document the byte-identical equivalence the delegations
    rely on. *)

open Alcotest

(* keeper_event_bridge_error_json.ml:12 — billable total excludes cache tokens. *)
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

(* context_compact_oas.ml:85 — every role variant maps to its canonical wire string. *)
let test_role_to_string () =
  check string "system" "system" (Agent_sdk.Types.role_to_string Agent_sdk.Types.System);
  check string "user" "user" (Agent_sdk.Types.role_to_string Agent_sdk.Types.User);
  check string "assistant" "assistant"
    (Agent_sdk.Types.role_to_string Agent_sdk.Types.Assistant);
  check string "tool" "tool" (Agent_sdk.Types.role_to_string Agent_sdk.Types.Tool)

(* sdk_tool_contract.ml:253 — strict [None] on unknown (#8832 drift WARN driver). *)
let test_param_type_of_string_strict_option () =
  let opt s = Agent_sdk.Types.param_type_of_string s |> Result.to_option in
  check bool "string" true (opt "string" = Some Agent_sdk.Types.String);
  check bool "integer" true (opt "integer" = Some Agent_sdk.Types.Integer);
  check bool "number" true (opt "number" = Some Agent_sdk.Types.Number);
  check bool "boolean" true (opt "boolean" = Some Agent_sdk.Types.Boolean);
  check bool "array" true (opt "array" = Some Agent_sdk.Types.Array);
  check bool "object" true (opt "object" = Some Agent_sdk.Types.Object);
  check bool "unknown -> None (strict, #8832)" true (opt "definitely-not-a-type" = None)

(* keeper_run_tools_setup.ml:168 — input schema shape equals the prior hand-built JSON:
   ordered properties, {type; description} per param, required = required names. *)
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

let suite =
  [ test_case "total_tokens billable" `Quick test_total_tokens
  ; test_case "role_to_string variants" `Quick test_role_to_string
  ; test_case "param_type_of_string strict option" `Quick test_param_type_of_string_strict_option
  ; test_case "params_to_input_schema shape" `Quick test_params_to_input_schema_shape
  ]

let () = run "oas_canonical_delegation_contract" [ "contract", suite ]
