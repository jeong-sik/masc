open Dashboard_http_keeper_types

let keeper_trust_json ?(include_receipt = false)
    (config : Coord.config) (meta : Keeper_types.keeper_meta) =
  let latest_receipt = Keeper_execution_receipt.latest_json config meta.name in
  let runtime_trust = Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta in
  let sandbox_json =
    match latest_receipt with
    | Some receipt -> Yojson.Safe.Util.member "sandbox" receipt
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
    | Some receipt -> Yojson.Safe.Util.member "approval" receipt
    | None -> `Assoc [ ("profile", `Null); ("derived", `Bool false) ]
  in
  let cascade_json =
    let cascade_ref_json =
      match meta.cascade_ref with
      | Some ref_ -> Cascade_ref.cascade_ref_to_json ref_
      | None -> `Null
    in
    match latest_receipt with
    | Some receipt -> (
        match Yojson.Safe.Util.member "cascade" receipt with
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
    | Some receipt -> json_string_list_member "requested_tools" receipt
    | None -> []
  in
  let required_tools, required_tool_candidates, missing_required_tools =
    match latest_receipt with
    | Some receipt ->
        let surface = Yojson.Safe.Util.member "tool_surface" receipt in
        ( json_string_list_member "required_tools" surface,
          json_string_list_member "required_tool_candidates" surface,
          json_string_list_member "missing_required_tools" surface )
    | None -> ([], [], [])
  in
  let tools_used =
    match latest_receipt with
    | Some receipt -> json_string_list_member "tools_used" receipt
    | None -> []
  in
  let unexpected_tools =
    match latest_receipt with
    | Some receipt -> json_string_list_member "unexpected_tools" receipt
    | None -> []
  in
  `Assoc
    [
      ( "last_outcome",
        match latest_receipt with
        | Some receipt -> Yojson.Safe.Util.member "outcome" receipt
        | None -> `String "not_run" );
      ( "terminal_reason_code",
        match latest_receipt with
        | Some receipt -> Yojson.Safe.Util.member "terminal_reason_code" receipt
        | None -> `String "no_receipt" );
      ( "operator_disposition",
        match latest_receipt with
        | Some receipt -> Yojson.Safe.Util.member "operator_disposition" receipt
        | None -> `String "not_run" );
      ( "operator_disposition_reason",
        match latest_receipt with
        | Some receipt -> Yojson.Safe.Util.member "operator_disposition_reason" receipt
        | None -> `String "no_receipt" );
      ( "tool_contract_result",
        match latest_receipt with
        | Some receipt -> Yojson.Safe.Util.member "tool_contract_result" receipt
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
      ("cascade", cascade_json);
      ("disposition", Yojson.Safe.Util.member "disposition" runtime_trust);
      ("disposition_reason", Yojson.Safe.Util.member "disposition_reason" runtime_trust);
      ("needs_attention", Yojson.Safe.Util.member "needs_attention" runtime_trust);
      ("attention_reason", Yojson.Safe.Util.member "attention_reason" runtime_trust);
      ("next_human_action", Yojson.Safe.Util.member "next_human_action" runtime_trust);
      ("approval_state", Yojson.Safe.Util.member "approval" runtime_trust);
      ("execution_summary", Yojson.Safe.Util.member "execution" runtime_trust);
      ( "latest_terminal_reason",
        Yojson.Safe.Util.member "latest_terminal_reason" runtime_trust );
      ("latest_next_action", Yojson.Safe.Util.member "latest_next_action" runtime_trust);
      ("latest_causal_event", Yojson.Safe.Util.member "latest_causal_event" runtime_trust);
      ( "last_receipt_at",
        match latest_receipt with
        | Some receipt -> Yojson.Safe.Util.member "ended_at" receipt
        | None -> `Null );
      ( "last_error",
        match latest_receipt with
        | Some receipt -> Yojson.Safe.Util.member "error" receipt
        | None -> `Null );
      ( "last_receipt",
        if include_receipt then
          match latest_receipt with
          | Some receipt -> receipt
          | None -> `Null
        else
          `Null );
    ]
