type observed =
  { reported_tool_names : string list
  ; observed_tool_names : string list
  ; tool_names : string list
  ; canonical_tool_names : string list
  ; unexpected_tool_names : string list
  ; valid_tool_calls_present : bool
  }

let analyze
      ~base_path
      ~keeper_name
      ~requested_tool_names_seen
      ~tool_usage_before
      ~tool_calls
      content
  =
  let reported_tool_names =
    List.filter_map
      (function
        | Agent_sdk.Types.ToolUse { name; _ } -> Some name
        | _ -> None)
      content
  in
  let tool_usage_after =
    Keeper_tool_disclosure.keeper_tool_usage_snapshot ~base_path ~keeper_name
  in
  let registry_observed_tool_names =
    Keeper_tool_disclosure.tool_usage_delta
      ~before:tool_usage_before
      ~after:tool_usage_after
  in
  let hook_observed_tool_names =
    List.rev_map
      (fun (detail : Keeper_agent_result.tool_call_detail) -> detail.tool_name)
      tool_calls
  in
  let observed_tool_names =
    Keeper_tool_disclosure.merge_observed_tool_names
      ~registry_observed_tool_names
      ~hook_observed_tool_names
  in
  let tool_names =
    Keeper_tool_disclosure.merge_reported_and_observed_tool_names
      ~reported_tool_names
      ~observed_tool_names
  in
  let canonical_tool_names =
    List.map Keeper_tool_resolution.canonical_tool_name_observed tool_names
  in
  let unexpected_tool_names =
    Keeper_tool_disclosure.unexpected_tool_names
      ~allowed_tool_names:requested_tool_names_seen
      ~tool_names:canonical_tool_names
  in
  let valid_tool_calls_present =
    Keeper_tool_disclosure.has_valid_tool_call
      ~unexpected_tool_names
      ~tool_names:canonical_tool_names
  in
  { reported_tool_names
  ; observed_tool_names
  ; tool_names
  ; canonical_tool_names
  ; unexpected_tool_names
  ; valid_tool_calls_present
  }
;;
