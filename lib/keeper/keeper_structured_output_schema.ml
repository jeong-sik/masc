(** Provider-native JSON schemas for keeper LLM sub-call producers. *)

let string_schema = `Assoc [ "type", `String "string" ]
let integer_schema = `Assoc [ "type", `String "integer" ]
let nullable_string_schema = `Assoc [ "type", `List [ `String "string"; `String "null" ] ]

let string_array_schema =
  `Assoc [ "type", `String "array"; "items", string_schema ]
;;

let enum_schema values =
  `Assoc
    [ "type", `String "string"
    ; "enum", `List (List.map (fun value -> `String value) values)
    ]
;;

let nullable_enum_schema values =
  `Assoc
    [ "type", `List [ `String "string"; `String "null" ]
    ; "enum", `List ((`Null) :: List.map (fun value -> `String value) values)
    ]
;;

let object_schema ~required properties =
  `Assoc
    [ "type", `String "object"
    ; "additionalProperties", `Bool false
    ; "properties", `Assoc properties
    ; "required", `List (List.map (fun key -> `String key) required)
    ]
;;

let category_tokens =
  Keeper_memory_os_types.all_categories
  |> List.map Keeper_memory_os_types.category_to_string
;;

let librarian_claim_kind_tokens =
  Keeper_memory_os_types.librarian_claim_kinds
  |> List.map Keeper_memory_os_types.claim_kind_to_string
;;

let librarian_claim_schema =
  let fields =
    [ Keeper_librarian.wire_field_claim, string_schema
    ; Keeper_librarian.wire_field_category, enum_schema category_tokens
    ; Keeper_librarian.wire_field_source_turn, integer_schema
    ; Keeper_librarian.wire_field_source_tool_call_id, nullable_string_schema
    ; Keeper_librarian.wire_field_claim_id, nullable_string_schema
    ; Keeper_librarian.wire_field_claim_kind, nullable_enum_schema librarian_claim_kind_tokens
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let librarian_episode_output_schema =
  let fields =
    [ Keeper_librarian.wire_field_episode_summary, string_schema
    ; ( Keeper_librarian.wire_field_claims
      , `Assoc [ "type", `String "array"; "items", librarian_claim_schema ] )
    ; Keeper_librarian.wire_field_open_items, string_array_schema
    ; Keeper_librarian.wire_field_constraints, string_array_schema
    ; Keeper_librarian.wire_field_preserved_tool_refs, string_array_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let consolidation_group_schema =
  let fields =
    [ ( Keeper_memory_os_consolidation.wire_field_member_indices
      , `Assoc [ "type", `String "array"; "items", integer_schema ] )
    ; Keeper_memory_os_consolidation.wire_field_consolidated_claim, string_schema
    ; Keeper_memory_os_consolidation.wire_field_category, enum_schema category_tokens
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let consolidation_plan_output_schema =
  let fields =
    [ ( Keeper_memory_os_consolidation.wire_field_groups
      , `Assoc [ "type", `String "array"; "items", consolidation_group_schema ] )
    ; ( Keeper_memory_os_consolidation.wire_field_drop_indices
      , `Assoc [ "type", `String "array"; "items", integer_schema ] )
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let memory_bank_summary_output_schema =
  let fields = [ "summary", string_schema ] in
  object_schema ~required:(List.map fst fields) fields
;;

let vision_analyze_output_schema =
  let fields = [ "text", string_schema ] in
  object_schema ~required:(List.map fst fields) fields
;;

let apply_to_provider_config schema (provider_cfg : Llm_provider.Provider_config.t) =
  { provider_cfg with
    response_format = Agent_sdk.Types.JsonSchema schema
  ; output_schema = Some schema
  }
;;

let validate_provider_config schema provider_cfg =
  provider_cfg
  |> apply_to_provider_config schema
  |> Llm_provider.Provider_config.validate_output_schema_request
;;

let provider_config_accepts_schema schema provider_cfg =
  match validate_provider_config schema provider_cfg with
  | Ok () -> true
  | Error _ -> false
;;
