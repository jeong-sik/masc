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

let allows_additional_properties schema =
  match schema_member "additionalProperties" schema with
  | Some (`Bool value) -> value
  | _ -> false
;;

let operator_recommended_action_schema () =
  Keeper_structured_output_schema.operator_judge_output_schema
  |> schema_property "workspace"
  |> schema_property "recommended_action"
;;

let governance_recommended_action_schema () =
  Keeper_structured_output_schema.governance_judge_output_schema
  |> schema_property "items"
  |> schema_items
  |> schema_property "recommended_action"
;;

let test_operator_judge_schema_uses_action_approval_ssot () =
  let action_schema =
    operator_recommended_action_schema () |> schema_property "action_type"
  in
  check
    (list string)
    "operator action enum"
    (List.sort String.compare Operator_approval.allowed_actions)
    (enum_strings action_schema);
  check
    bool
    "goal completion decision is schema-admitted"
    true
    (List.mem
       Operator_action_constants.goal_completion_decision
       (enum_strings action_schema))
;;

let test_operator_judge_schema_allows_payload_objects () =
  let payload_schema =
    operator_recommended_action_schema () |> schema_property "suggested_payload"
  in
  check bool "suggested_payload admits object members" true
    (allows_additional_properties payload_schema)
;;

let test_governance_judge_schema_uses_resolved_tool_ssot () =
  let tool_schema =
    governance_recommended_action_schema () |> schema_property "resolved_tool"
  in
  check
    (list string)
    "governance resolved_tool enum"
    (List.sort String.compare Tool_name.Operator_remote_name.all_strings)
    (enum_strings tool_schema)
;;

let test_operator_remote_tool_name_ssot_matches_remote_schemas () =
  let schema_names =
    Operator_tool.remote_schemas
    |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
    |> List.sort String.compare
  in
  check
    (list string)
    "operator remote schema names"
    (List.sort String.compare Tool_name.Operator_remote_name.all_strings)
    schema_names;
  check
    (list string)
    "operator remote exported names"
    (List.sort String.compare Tool_name.Operator_remote_name.all_strings)
    (List.sort String.compare Operator_tool.remote_tool_names)
;;

let test_governance_judge_schema_allows_payload_objects () =
  let payload_schema =
    governance_recommended_action_schema () |> schema_property "payload_preview"
  in
  check bool "payload_preview admits object members" true
    (allows_additional_properties payload_schema)
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
  check bool "fusion schema exposes parser wire fields" true true
;;

let test_verification_verdict_schema_uses_core_ssot () =
  let schema = Keeper_structured_output_schema.verification_verdict_output_schema in
  check
    (list string)
    "verification verdict required fields"
    [ "evidence"; "reason"; "verdict" ]
    (required_strings schema);
  check
    (list string)
    "verification verdict enum"
    (List.sort String.compare Verifier_core.valid_verdict_strings)
    (schema |> schema_property "verdict" |> enum_strings);
  check bool "verification verdict is closed" false
    (allows_additional_properties schema);
  let evidence_schema =
    schema |> schema_property "evidence" |> schema_items
  in
  check
    (list string)
    "verification evidence required fields"
    [ "line"; "path"; "quote" ]
    (required_strings evidence_schema);
  check bool "verification evidence is closed" false
    (allows_additional_properties evidence_schema)
;;

let test_anti_rationalization_verdict_schema_uses_task_ssot () =
  let schema =
    Keeper_structured_output_schema.anti_rationalization_verdict_output_schema
  in
  check
    (list string)
    "anti-rationalization verdict required fields"
    [ "reason"; "verdict" ]
    (required_strings schema);
  check
    (list string)
    "anti-rationalization verdict enum"
    (List.sort String.compare Task.Anti_rationalization.valid_verdict_strings)
    (schema |> schema_property "verdict" |> enum_strings);
  check bool "anti-rationalization verdict is closed" false
    (allows_additional_properties schema)
;;

let () =
  run
    "keeper-structured-output-schema"
    [ ( "dashboard schemas"
      , [ test_case
            "operator judge schema uses action approval SSOT"
            `Quick
            test_operator_judge_schema_uses_action_approval_ssot
        ; test_case
            "operator judge schema admits payload objects"
            `Quick
            test_operator_judge_schema_allows_payload_objects
        ; test_case
            "governance judge schema uses resolved-tool SSOT"
            `Quick
            test_governance_judge_schema_uses_resolved_tool_ssot
        ; test_case
            "operator remote tool-name SSOT matches remote schemas"
            `Quick
            test_operator_remote_tool_name_ssot_matches_remote_schemas
        ; test_case
            "governance judge schema admits payload objects"
            `Quick
            test_governance_judge_schema_allows_payload_objects
        ] )
    ; ( "fusion schemas"
      , [ test_case
            "fusion judge schema uses parser wire contract"
            `Quick
            test_fusion_judge_schema_uses_parser_wire_contract
        ] )
    ; ( "verdict schemas"
      , [ test_case
            "verification verdict schema uses core SSOT"
            `Quick
            test_verification_verdict_schema_uses_core_ssot
        ; test_case
            "anti-rationalization verdict schema uses task SSOT"
            `Quick
            test_anti_rationalization_verdict_schema_uses_task_ssot
        ] )
    ]
;;
