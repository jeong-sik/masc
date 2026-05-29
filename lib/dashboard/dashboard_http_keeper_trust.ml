open Dashboard_http_keeper_types

let keeper_trust_json ?(include_receipt = false)
    (config : Coord.config) (meta : Keeper_types.keeper_meta) =
  let latest_receipt = Keeper_execution_receipt.latest_json config meta.name in
  let runtime_trust =
    if include_receipt
    then Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta
    else Keeper_runtime_trust_snapshot.summary_json ~config ~meta
  in
  let rc key =
    match latest_receipt with
    | Some receipt -> Option.value ~default:`Null (Json_util.assoc_member_opt key receipt)
    | None -> `Null
  in
  let rt key = Option.value ~default:`Null (Json_util.assoc_member_opt key runtime_trust) in
  let sandbox_json =
    match latest_receipt with
    | Some receipt -> rc "sandbox"
    | None ->
        `Assoc
          [
            ("kind", `String (Keeper_types.sandbox_profile_to_string meta.sandbox_profile));
            ("sandbox_root", `String config.base_path);
            ("network_mode", `String (Keeper_types.network_mode_to_string meta.network_mode));
          ]
  in
  let approval_json =
    match latest_receipt with
    | Some _ -> rc "approval"
    | None -> `Assoc [ ("profile", `Null); ("derived", `Bool false) ]
  in
  let cascade_json =
    let cascade_ref_json =
      match meta.cascade_ref with
      | Some ref_ -> Cascade_ref.cascade_ref_to_json ref_
      | None -> `Null
    in
    match latest_receipt with
    | Some _ -> (
        match rc "cascade" with
        | `Assoc fields -> `Assoc (("cascade_ref", cascade_ref_json) :: fields)
        | other -> other)
    | None ->
        `Assoc
          [
            ("name", `String (Keeper_types.cascade_name_of_meta meta));
            ("cascade_ref", cascade_ref_json);
            ("selected_model", `Null);
            ("attempt_count", `Int 0);
            ("fallback_applied", `Bool false);
            ("outcome", `String "not_observed");
          ]
  in
  let requested_tools =
    match latest_receipt with
    | Some receipt -> Json_util.json_string_list_member "requested_tools" receipt
    | None -> []
  in
  let required_tools, required_tool_candidates, missing_required_tools =
    match latest_receipt with
    | Some receipt ->
        let surface = Option.value ~default:`Null (Json_util.assoc_member_opt "tool_surface" receipt) in
        ( Json_util.json_string_list_member "required_tools" surface,
          Json_util.json_string_list_member "required_tool_candidates" surface,
          Json_util.json_string_list_member "missing_required_tools" surface )
    | None -> ([], [], [])
  in
  let tools_used =
    match latest_receipt with
    | Some receipt -> Json_util.json_string_list_member "tools_used" receipt
    | None -> []
  in
  let unexpected_tools =
    match latest_receipt with
    | Some receipt -> Json_util.json_string_list_member "unexpected_tools" receipt
    | None -> []
  in
  `Assoc
    [
      ("last_outcome",
        match latest_receipt with
        | Some _ -> rc "outcome"
        | None -> `String "not_run");
      ("terminal_reason_code",
        match latest_receipt with
        | Some _ -> rc "terminal_reason_code"
        | None -> `String "no_receipt");
      ("operator_disposition",
        match latest_receipt with
        | Some _ -> rc "operator_disposition"
        | None -> `String "not_run");
      ("operator_disposition_reason",
        match latest_receipt with
        | Some _ -> rc "operator_disposition_reason"
        | None -> `String "no_receipt");
      ("tool_contract_result",
        match latest_receipt with
        | Some _ -> rc "tool_contract_result"
        | None -> `String "unknown");
      ("requested_tool_count", `Int (List.length requested_tools));
      ("required_tools", `List (List.map (fun value -> `String value) required_tools));
      ("required_tool_candidates",
        `List (List.map (fun value -> `String value) required_tool_candidates));
      ("missing_required_tools",
        `List (List.map (fun value -> `String value) missing_required_tools));
      ("tools_used", `List (List.map (fun value -> `String value) tools_used));
      ("unexpected_tools", `List (List.map (fun value -> `String value) unexpected_tools));
      ("unexpected_tool_count", `Int (List.length unexpected_tools));
      ("sandbox", sandbox_json);
      ("approval", approval_json);
      ("cascade", cascade_json);
      ("disposition", rt "disposition");
      ("disposition_reason", rt "disposition_reason");
      ("needs_attention", rt "needs_attention");
      ("attention_reason", rt "attention_reason");
      ("next_human_action", rt "next_human_action");
      ("approval_state", rt "approval");
      ("execution_summary", rt "execution");
      ("latest_terminal_reason", rt "latest_terminal_reason");
      ("latest_next_action", rt "latest_next_action");
      ("latest_causal_event", rt "latest_causal_event");
      ("last_receipt_at",
        match latest_receipt with
        | Some _ -> rc "ended_at"
        | None -> `Null);
      ("last_error",
        match latest_receipt with
        | Some _ -> rc "error"
        | None -> `Null);
      ("last_receipt",
        if include_receipt then
          match latest_receipt with
          | Some receipt -> receipt
          | None -> `Null
        else
          `Null);
    ]
