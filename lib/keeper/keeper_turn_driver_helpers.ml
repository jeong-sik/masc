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

let materialized_tool_names_after_lane ~effective_tools ~runtime_mcp_policy =
  let inline_names =
    List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) effective_tools
  in
  let runtime_names =
    match runtime_mcp_policy with
    | Some policy -> policy.Llm_provider.Llm_transport.allowed_tool_names
    | None -> []
  in
  Json_util.dedupe_keep_order (inline_names @ runtime_names)

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

let canonical_tool_name_for_lane_check name =
  match Agent_tool_descriptor_resolution.canonical_internal_name_for_tool_name name with
  | Some internal -> internal
  | None -> name

let canonical_tool_names_for_lane_check names =
  names |> List.map canonical_tool_name_for_lane_check |> Json_util.dedupe_keep_order

let dedupe_required_tool_names_for_lane_check names =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | name :: rest ->
      let canonical = canonical_tool_name_for_lane_check name in
      if List.mem canonical seen
      then loop seen acc rest
      else loop (canonical :: seen) (name :: acc) rest
  in
  loop [] [] names

let missing_required_tool_names_after_lane_by_name ~required_tool_names
    ~materialized_tool_names =
  let materialized_tool_names =
    canonical_tool_names_for_lane_check materialized_tool_names
  in
  required_tool_names
  |> dedupe_required_tool_names_for_lane_check
  |> List.filter (fun name ->
       let canonical = canonical_tool_name_for_lane_check name in
       not (List.mem canonical materialized_tool_names))

let missing_required_tool_names_after_lane ~required_tool_names ~effective_tools
    ~runtime_mcp_policy =
  let materialized_tool_names =
    materialized_tool_names_after_lane ~effective_tools ~runtime_mcp_policy
  in
  missing_required_tool_names_after_lane_by_name ~required_tool_names
    ~materialized_tool_names

let required_tool_lane_unavailable_error ~lane ~missing_required_tools
    ~materialized_tools =
  Agent_sdk.Error.Config
    (Agent_sdk.Error.InvalidConfig
       {
         field = "tool_support";
         detail =
           Printf.sprintf
             "required_tool_lane_unavailable: lane=%s missing_required_tools=[%s] \
              materialized_tools=[%s]"
             lane
             (String.concat ", " missing_required_tools)
             (String.concat ", " materialized_tools);
       })

let provider_rejection_for_required_tool_unsupported ~provider_label
    ~missing_required_tools =
  ({
     provider_label;
     reason =
       Printf.sprintf
         "required_tool_unsupported: provider=%s missing_required_tools=[%s]"
         provider_label
         (String.concat ", " missing_required_tools);
   }
    : Cascade_error_classify.provider_rejection)

let no_tool_capable_provider_of_pre_dispatch_rejections ~cascade_name
    ~configured_labels ~runtime_manifest_required_tool_names ~runtime_mcp_policy
    ~tools ~required_lane_provider_rejections ~pre_dispatch_provider_rejections =
  match runtime_manifest_required_tool_names, pre_dispatch_provider_rejections with
  | [], _ | _, [] -> None
  | _ ->
      let required_tool_names =
        match required_tool_names_for_no_tool_error ~runtime_mcp_policy ~tools with
        | [] -> Json_util.dedupe_keep_order runtime_manifest_required_tool_names
        | names -> names
      in
      Some
        (Cascade_error_classify.No_tool_capable_provider
           {
             cascade_name;
             configured_labels;
             required_tool_names;
             provider_rejections =
               required_lane_provider_rejections
               @ pre_dispatch_provider_rejections;
           })

type empty_candidate_classification =
  | Tool_capability_empty
  | Provider_unavailable

let classify_empty_candidates ~require_tool_choice_support ~require_tool_support
    ~original_candidate_count ~tool_filtered_candidate_count =
  if
    (require_tool_choice_support || require_tool_support)
    && original_candidate_count > 0
    && tool_filtered_candidate_count = 0
  then Tool_capability_empty
  else Provider_unavailable

let empty_candidate_classification_code = function
  | Tool_capability_empty -> "tool_capability_empty"
  | Provider_unavailable -> "provider_unavailable"

let fail_open_health_filtered_candidates
    ~(tool_filtered_candidates : 'a list)
    ~(health_filtered_candidates : 'a list)
  : 'a list * bool =
  match health_filtered_candidates with
  | [] when tool_filtered_candidates <> [] -> tool_filtered_candidates, true
  | _ -> health_filtered_candidates, false

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
       | Some reason ->
           Some
             ({
                provider_label =
                  Cascade_runtime_candidate.provider_label candidate;
                reason;
              }
               : Cascade_error_classify.provider_rejection))

let apply_stream_idle_timeout_default = function
  | Some _ as v -> v
  | None -> Some Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec

let checkpoint_after_attempt ?agent_ref = function
  | Some agent ->
      (match agent_ref with Some r -> r := Some agent | None -> ());
      Some (Agent_sdk.Agent.checkpoint agent)
  | None -> None
