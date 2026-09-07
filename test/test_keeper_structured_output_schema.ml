open Alcotest
open Masc

let schema_member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let schema_property key schema =
  match schema_member "properties" schema with
  | Some (`Assoc properties) ->
    (match List.assoc_opt key properties with
     | Some value -> value
     | None -> failf "missing schema property %S" key)
  | _ -> failf "schema has no object properties while looking for %S" key
;;

let schema_items schema =
  match schema_member "items" schema with
  | Some value -> value
  | None -> fail "schema has no items member"
;;

let enum_strings schema =
  match schema_member "enum" schema with
  | Some (`List values) ->
    values
    |> List.filter_map (function
      | `String value -> Some value
      | _ -> None)
    |> List.sort String.compare
  | _ -> fail "schema has no enum member"
;;

let required_strings schema =
  match schema_member "required" schema with
  | Some (`List values) ->
    values
    |> List.filter_map (function
      | `String value -> Some value
      | _ -> None)
    |> List.sort String.compare
  | _ -> fail "schema has no required member"
;;

let type_strings schema =
  match schema_member "type" schema with
  | Some (`List values) ->
    values
    |> List.filter_map (function
      | `String value -> Some value
      | _ -> None)
    |> List.sort String.compare
  | Some (`String value) -> [ value ]
  | _ -> fail "schema has no type member"
;;

let allows_additional_properties schema =
  match schema_member "additionalProperties" schema with
  | Some (`Bool value) -> value
  | _ -> false
;;

let has_no_response_format provider_cfg =
  match provider_cfg.Llm_provider.Provider_config.response_format with
  | Agent_core.Types.Off -> true
  | Agent_core.Types.JsonMode | Agent_core.Types.JsonSchema _ -> false
;;
let test_operator_remote_tool_name_ssot_matches_remote_schemas () =
  let schema_names =
    Operator_tool.remote_schemas
    |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
    |> List.sort String.compare
  in
  (* remote_tool_names is derived from remote_schemas, so their agreement is
     structural and not worth asserting. What is worth pinning is the policy
     those two express: which operator tools the remote profile advertises.
     Operator_tool.remote_schema decides it constructor by constructor, and
     masc_operator_judgment_write is deliberately absent. *)
  check
    (list string)
    "operator remote profile advertises exactly these"
    [ "masc_operator_action"
    ; "masc_operator_board_attention_quarantine_requeue"
    ; "masc_operator_confirm"
    ; "masc_operator_digest"
    ; "masc_operator_snapshot"
    ; "masc_operator_task_recovery_resolve"
    ]
    schema_names;
  check
    bool
    "judgment_write stays off the remote profile"
    false
    (List.mem "masc_operator_judgment_write" Operator_tool.remote_tool_names);
  check bool "Board quarantine recovery cannot bypass operator profile" false
    (Tool_catalog.allow_direct_call
       "masc_operator_board_attention_quarantine_requeue")
  ;
  check bool "task recovery cannot bypass operator profile" false
    (Tool_catalog.allow_direct_call "masc_operator_task_recovery_resolve")
;;

let test_fusion_judge_schema_uses_parser_wire_contract () =
  let schema = Keeper_structured_output_schema.fusion_judge_output_schema in
  check
    (list string)
    "fusion judge required fields"
    (List.sort
       String.compare
       [ Fusion_judge_parse.wire_field_decision
       ; Fusion_judge_parse.wire_field_resolved_answer
       ])
    (required_strings schema);
  let decision_kind_schema =
    schema
    |> schema_property Fusion_judge_parse.wire_field_decision
    |> schema_property Fusion_judge_parse.wire_field_decision_kind
  in
  check
    (list string)
    "fusion decision enum"
    (List.sort
       String.compare
       [ Fusion_judge_parse.wire_decision_answer
       ; Fusion_judge_parse.wire_decision_insufficient
       ; Fusion_judge_parse.wire_decision_recommend
       ])
    (enum_strings decision_kind_schema);
  let _consensus_text_schema =
    schema
    |> schema_property Fusion_judge_parse.wire_field_consensus
    |> schema_items
    |> schema_property Fusion_judge_parse.wire_field_consensus_text
  in
  let _position_stance_schema =
    schema
    |> schema_property Fusion_judge_parse.wire_field_contradictions
    |> schema_items
    |> schema_property Fusion_judge_parse.wire_field_positions
    |> schema_items
    |> schema_property Fusion_judge_parse.wire_field_stance
  in
  ()
;;

 let test_librarian_claim_schema_is_closed () =
  let claim_schema =
    Keeper_structured_output_schema.librarian_current_output_schema
    |> schema_property Keeper_librarian.wire_field_new_claims
    |> schema_items
  in
  check
    (list string)
    "librarian claim required fields"
    (List.sort String.compare Keeper_librarian.wire_claim_fields)
    (required_strings claim_schema);
  check bool "librarian claim schema is closed" false
    (allows_additional_properties claim_schema);
  (* The two Board provenance fields are answered on every claim, null when
     the claim came from the transcript, so strict schema modes accept it. *)
  let type_tokens schema =
    match schema with
    | `Assoc fields ->
      (match List.assoc_opt "type" fields with
       | Some (`List values) ->
         List.filter_map (function `String s -> Some s | _ -> None) values
       | Some (`String s) -> [ s ]
       | _ -> [])
    | _ -> []
  in
  List.iter
    (fun field ->
       check
         (list string)
         (field ^ " is a required nullable string")
         [ "null"; "string" ]
         (List.sort String.compare (type_tokens (schema_property field claim_schema))))
    [ Keeper_memory_os_types.wire_field_board_post_id
    ; Keeper_memory_os_types.wire_field_board_comment_id
    ]
;;

let test_librarian_dropped_schema_is_closed () =
  let schema = Keeper_structured_output_schema.librarian_current_output_schema in
  check
    (list string)
    "librarian top-level required fields"
    (List.sort String.compare Keeper_librarian.wire_current_fields)
    (required_strings schema);
  let dropped_schema =
    schema
    |> schema_property Keeper_librarian.wire_field_dropped
    |> schema_items
  in
  check
    (list string)
    "librarian dropped required fields"
    (List.sort String.compare Keeper_librarian.wire_dropped_fields)
    (required_strings dropped_schema);
  check bool "librarian dropped schema is closed" false
    (allows_additional_properties dropped_schema)
;;

(* The reviewer config must reach json_object-only providers. Counterfactual
   first: a native schema request on a Glm-kind config is rejected by the AGENT_CORE
   contract — that rejection is exactly what left every task nonterminal
   fleet-wide on a Glm evaluator runtime (2026-07-21). The reviewer transform
   must therefore request no wire format at all and validate on Glm. *)
let glm_provider_config () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Glm
    ~model_id:"glm-5-turbo"
    ~base_url:"https://glm.invalid/api/paas/v4"
    ()
;;

let test_anti_rationalization_reviewer_config_reaches_glm () =
  let reviewer =
    Keeper_structured_output_schema.anti_rationalization_reviewer_provider_config
      (glm_provider_config ())
  in
  check bool "reviewer config carries no wire response format" true
    (has_no_response_format reviewer)
;;

let test_anti_rationalization_reviewer_config_clears_preset_response_format () =
  let preset =
    { (glm_provider_config ()) with
      response_format = Agent_core.Types.JsonMode
    }
  in
  let reviewer =
    Keeper_structured_output_schema.anti_rationalization_reviewer_provider_config preset
  in
  check
    bool
    "a pre-set response format on the incoming config is cleared, not inherited"
    true
    (has_no_response_format reviewer)
;;


let test_board_attention_batch_schema_uses_contract_ssot () =
  let schema =
    Keeper_structured_output_schema.board_attention_judgment_batch_output_schema
  in
  check
    (list string)
    "Board attention batch required fields"
    [ "verdicts" ]
    (required_strings schema);
  let item = schema |> schema_property "verdicts" |> schema_items in
  check
    (list string)
    "Board attention batch item required fields"
    [ "candidate_id"; "decision"; "rationale" ]
    (required_strings item);
  check
    (list string)
    "Board attention batch decision enum"
    (List.sort String.compare Keeper_board_attention_judgment.decision_tokens)
    (item |> schema_property "decision" |> enum_strings);
  check bool "Board attention batch item is closed" false
    (allows_additional_properties item);
  check bool "Board attention batch envelope is closed" false
    (allows_additional_properties schema)
;;


(* Regression guard for #25494. The deterministic subcall shape used to be
   hand-copied at each site; the second site's comment read "Mirror the
   librarian tuning". Thinking suppression is the load-bearing part —
   reasoning-capable providers otherwise spend the whole output budget on
   thinking and return empty visible text (consolidation logged 256
   consecutive Empty_response outcomes that way on 2026-07-20). These pin
   the fields so removing the suppression from the shared helper fails here
   instead of silently at one call site. *)

let base_provider_cfg () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Anthropic
    ~model_id:"fake"
    ~base_url:"http://localhost"
    ()
;;

let test_deterministic_subcall_suppresses_thinking () =
  let cfg =
    Keeper_structured_output_schema.for_deterministic_subcall
      ~max_tokens:(Some 512)
      (base_provider_cfg ())
  in
  check
    (option bool)
    "enable_thinking must be explicitly false"
    (Some false)
    cfg.Llm_provider.Provider_config.enable_thinking;
  check
    (option bool)
    "preserve_thinking must be explicitly false"
    (Some false)
    cfg.Llm_provider.Provider_config.preserve_thinking;
  check
    (option bool)
    "clear_thinking must be explicitly true"
    (Some true)
    cfg.Llm_provider.Provider_config.clear_thinking;
  check
    bool
    "thinking_budget must be cleared"
    true
    (cfg.Llm_provider.Provider_config.thinking_budget = None)
;;

let test_deterministic_subcall_disables_tool_surface () =
  let cfg =
    Keeper_structured_output_schema.for_deterministic_subcall
      ~max_tokens:None
      (base_provider_cfg ())
  in
  check
    bool
    "tool_choice must be cleared"
    true
    (cfg.Llm_provider.Provider_config.tool_choice = None);
  check
    bool
    "parallel tool use must be disabled"
    true
    cfg.Llm_provider.Provider_config.disable_parallel_tool_use
;;

let test_deterministic_subcall_passes_max_tokens_through () =
  let cfg =
    Keeper_structured_output_schema.for_deterministic_subcall
      ~max_tokens:(Some 8192)
      (base_provider_cfg ())
  in
  check
    (option int)
    "max_tokens is the caller's, not the helper's"
    (Some 8192)
    cfg.Llm_provider.Provider_config.max_tokens
;;

let () =
  run
    "keeper-structured-output-schema"
    [ ( "dashboard schemas"
      , [ test_case
            "operator remote tool-name SSOT matches remote schemas"
            `Quick
            test_operator_remote_tool_name_ssot_matches_remote_schemas
        ] )
    ; ( "fusion schemas"
      , [ test_case
            "fusion judge schema uses parser wire contract"
            `Quick
            test_fusion_judge_schema_uses_parser_wire_contract
        ] )
    ; ( "librarian schemas"
      , [ test_case
            "minimal claim fields remain required"
            `Quick
            test_librarian_claim_schema_is_closed
        ; test_case
            "dropped statements are required and closed"
            `Quick
            test_librarian_dropped_schema_is_closed
        ] )
    ; ( "verdict schemas"
      , [ test_case
            "anti-rationalization reviewer config reaches a Glm provider"
            `Quick
            test_anti_rationalization_reviewer_config_reaches_glm
        ; test_case
            "anti-rationalization reviewer config clears a pre-set response format"
            `Quick
            test_anti_rationalization_reviewer_config_clears_preset_response_format
        ; test_case
            "Board attention batch schema uses contract SSOT"
            `Quick
            test_board_attention_batch_schema_uses_contract_ssot
        ] )
    ; ( "deterministic_subcall_shape"
      , [ test_case
            "thinking is suppressed"
            `Quick
            test_deterministic_subcall_suppresses_thinking
        ; test_case
            "tool surface is disabled"
            `Quick
            test_deterministic_subcall_disables_tool_surface
        ; test_case
            "max_tokens passes through"
            `Quick
            test_deterministic_subcall_passes_max_tokens_through
        ] )
    ]
;;
