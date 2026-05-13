(** Keeper_turn_driver_helpers — pure helper functions extracted from
    [Keeper_turn_driver].

    These are top-level pure functions (no closures over outer state)
    that compute provider-attempt timeout bounds, health-key derivations,
    tool-name aggregations, etc. Lifting them out of the 1459-LOC
    [keeper_turn_driver.ml] is a foundation step toward the eventual
    A/B/C decomposition (Agent SDK call / cascade strategy / keeper
    bookkeeping) deferred from RFC-0047 Phase 4.

    No behavior change. Mechanical extraction.

    @since RFC-0048 — keeper_turn_driver split, helpers slice *)

let required_tool_names_for_no_tool_error ~runtime_mcp_policy ~tools =
  let names =
    match runtime_mcp_policy with
    | Some policy
      when policy.Llm_provider.Llm_transport.allowed_tool_names <> [] ->
        policy.allowed_tool_names
    | _ -> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) tools
  in
  List.sort_uniq String.compare names

let dedupe_keep_order values =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | value :: rest ->
      if List.mem value seen then loop seen acc rest
      else loop (value :: seen) (value :: acc) rest
  in
  loop [] [] values

let materialized_tool_names_after_lane ~effective_tools ~runtime_mcp_policy =
  let inline_names =
    List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) effective_tools
  in
  let runtime_names =
    match runtime_mcp_policy with
    | Some policy -> policy.Llm_provider.Llm_transport.allowed_tool_names
    | None -> []
  in
  dedupe_keep_order (inline_names @ runtime_names)

let resolved_tool_lane_label ~effective_tools ~runtime_mcp_policy =
  let inline_names =
    List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) effective_tools
  in
  let runtime_names =
    match runtime_mcp_policy with
    | Some policy -> policy.Llm_provider.Llm_transport.allowed_tool_names
    | None -> []
  in
  match inline_names <> [], runtime_names <> [], runtime_mcp_policy with
  | true, true, _ -> "mixed"
  | true, false, _ -> "inline"
  | false, true, _ -> "runtime_mcp"
  | false, false, Some _ -> "runtime_mcp_connect_only"
  | false, false, None -> "none"

let missing_required_tool_names_after_lane_by_name ~required_tool_names
    ~materialized_tool_names =
  required_tool_names
  |> dedupe_keep_order
  |> List.filter (fun name -> not (List.mem name materialized_tool_names))

let missing_required_tool_names_after_lane ~required_tool_names ~effective_tools
    ~runtime_mcp_policy =
  let materialized_tool_names =
    materialized_tool_names_after_lane ~effective_tools ~runtime_mcp_policy
  in
  missing_required_tool_names_after_lane_by_name ~required_tool_names
    ~materialized_tool_names

let provider_rejections_for_no_tool_error
    ~keeper_name ?runtime_mcp_policy ~tools
    ~require_tool_choice_support ~require_tool_support candidates =
  candidates
  |> List.filter_map (fun candidate ->
       match
         Cascade_runtime_candidate.tool_filter_rejection_label
           ~keeper_name ?runtime_mcp_policy ~tools
           ~require_tool_choice_support ~require_tool_support candidate
       with
       | None -> None
       | Some reason -> Some ({ reason } : Cascade_error_classify.provider_rejection))

let apply_stream_idle_timeout_default = function
  | Some _ as v -> v
  | None -> Some Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec

let checkpoint_after_attempt ?agent_ref = function
  | Some agent ->
      (match agent_ref with Some r -> r := Some agent | None -> ());
      Some (Agent_sdk.Agent.checkpoint agent)
  | None -> None
