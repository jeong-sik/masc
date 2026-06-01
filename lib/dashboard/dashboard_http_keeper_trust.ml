open Dashboard_http_keeper_types

let keeper_trust_json ?(include_receipt = false)
    (config : Workspace.config) (meta : Keeper_meta_contract.keeper_meta) =
  let latest_receipt = Keeper_execution_receipt.latest_json config meta.name in
  let runtime_trust =
    if include_receipt
    then Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta
    else Keeper_runtime_trust_snapshot.summary_json ~config ~meta
  in
  let sandbox_json =
    match latest_receipt with
    | Some receipt -> Option.value ~default:`Null (Json_util.assoc_member_opt "sandbox" receipt)
    | None ->
        `Assoc
          [
            ("kind", `String (Keeper_types_profile_sandbox.sandbox_profile_to_string meta.sandbox_profile));
            ("sandbox_root", `String config.base_path);
            ("network_mode", `String (Keeper_types_profile_sandbox.network_mode_to_string meta.network_mode));
          ]
  in
  let approval_json =
    match latest_receipt with
    | Some receipt -> Option.value ~default:`Null (Json_util.assoc_member_opt "approval" receipt)
    | None -> `Assoc [ ("profile", `Null); ("derived", `Bool false) ]
  in
  let runtime_json =
    match latest_receipt with
    | Some receipt -> (
        match Json_util.assoc_member_opt "runtime" receipt with
        | Some json -> json
        | None -> `Null)
    | None ->
        `Assoc
          [
            ("name", `String (Keeper_meta_contract.runtime_id_of_meta meta));
            ("selected_model", `Null);
            ("attempt_count", `Int 0);
            ("fallback_applied", `Bool false);
            ("outcome", `String "not_observed");
          ]
  in
  let requested_tools =
    match latest_receipt with
    | Some receipt -> Json_util.get_string_list receipt "requested_tools"
    | None -> []
  in
  let required_tools, required_tool_candidates, missing_required_tools =
    match latest_receipt with
    | Some receipt ->
        let surface = Option.value ~default:`Null (Json_util.assoc_member_opt "tool_surface" receipt) in
        ( Json_util.get_string_list surface "required_tools",
          Json_util.get_string_list surface "required_tool_candidates",
          Json_util.get_string_list surface "missing_required_tools" )
    | None -> ([], [], [])
  in
  let tools_used =
    match latest_receipt with
    | Some receipt -> Json_util.get_string_list receipt "tools_used"
    | None -> []
  in
  let unexpected_tools =
    match latest_receipt with
    | Some receipt -> Json_util.get_string_list receipt "unexpected_tools"
    | None -> []
  in
  `Assoc
    [
      ( "last_outcome",
        match latest_receipt with
        | Some receipt -> Option.value ~default:(`String "not_run") (Json_util.assoc_member_opt "outcome" receipt)
        | None -> `String "not_run" );
      ( "terminal_reason_code",
        match latest_receipt with
        | Some receipt -> Option.value ~default:(`String "no_receipt") (Json_util.assoc_member_opt "terminal_reason_code" receipt)
        | None -> `String "no_receipt" );
      ( "operator_disposition",
        match latest_receipt with
        | Some receipt -> Option.value ~default:(`String "not_run") (Json_util.assoc_member_opt "operator_disposition" receipt)
        | None -> `String "not_run" );
      ( "operator_disposition_reason",
        match latest_receipt with
        | Some receipt -> Option.value ~default:(`String "no_receipt") (Json_util.assoc_member_opt "operator_disposition_reason" receipt)
        | None -> `String "no_receipt" );
      ( "tool_contract_result",
        match latest_receipt with
        | Some receipt -> Option.value ~default:(`String "unknown") (Json_util.assoc_member_opt "tool_contract_result" receipt)
        | None -> `String "unknown" );
      ("requested_tool_count", `Int (List.length requested_tools));
      ("required_tools", `List (List.map (fun value -> `String value) required_tools));
      ( "required_tool_candidates",
        `List (List.map (fun value -> `String value) required_tool_candidates) );
      ( "missing_required_tools",
        `List (List.map (fun value -> `String value) missing_required_tools) );
      ("tools_used", `List (List.map (fun value -> `String value) tools_used));
      ("unexpected_tools", `List (List.map (fun value -> `String value) unexpected_tools));
      ("unexpected_tool_count", `Int (List.length unexpected_tools));
      ("sandbox", sandbox_json);
      ("approval", approval_json);
      ("runtime", runtime_json);
      ("disposition", Option.value ~default:`Null (Json_util.assoc_member_opt "disposition" runtime_trust));
      ("disposition_reason", Option.value ~default:`Null (Json_util.assoc_member_opt "disposition_reason" runtime_trust));
      ("needs_attention", Option.value ~default:`Null (Json_util.assoc_member_opt "needs_attention" runtime_trust));
      ("attention_reason", Option.value ~default:`Null (Json_util.assoc_member_opt "attention_reason" runtime_trust));
      ("next_human_action", Option.value ~default:`Null (Json_util.assoc_member_opt "next_human_action" runtime_trust));
      ("approval_state", Option.value ~default:`Null (Json_util.assoc_member_opt "approval" runtime_trust));
      ("execution_summary", Option.value ~default:`Null (Json_util.assoc_member_opt "execution" runtime_trust));
      ( "latest_terminal_reason",
        Option.value ~default:`Null (Json_util.assoc_member_opt "latest_terminal_reason" runtime_trust) );
      ("latest_next_action", Option.value ~default:`Null (Json_util.assoc_member_opt "latest_next_action" runtime_trust));
      ("latest_causal_event", Option.value ~default:`Null (Json_util.assoc_member_opt "latest_causal_event" runtime_trust));
      ( "last_receipt_at",
        match latest_receipt with
        | Some receipt -> Option.value ~default:`Null (Json_util.assoc_member_opt "ended_at" receipt)
        | None -> `Null );
      ( "last_error",
        match latest_receipt with
        | Some receipt -> Option.value ~default:`Null (Json_util.assoc_member_opt "error" receipt)
        | None -> `Null );
      ( "last_receipt",
        if include_receipt then
          match latest_receipt with
          | Some receipt -> receipt
          | None -> `Null
        else
          `Null );
    ]
