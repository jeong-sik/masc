(** Runtime_oas_runner — Eio context, cascade resolution, runtime MCP policy.

    Extracted from oas_worker_named.ml (God file decomposition).
    Provides cascade profile defaults, Eio context validation,
    provider resolution, and tool-support filtering.

    @since God file decomposition *)

(* Execution-model defaults (RFC-0206: delegate to Runtime_model_labels;
   the deleted Cascade_runtime/cascade-name catalog layer is annihilated). *)

let default_config_path = Runtime.config_path

let default_model_strings () = Runtime_model_labels.default_model_strings ()

(* Named model execution *)

let require_eio ?sw ?net () =
  let sw =
    match sw with
    | Some s -> Some s
    | None -> Eio_context.get_switch_opt ()
  in
  let net =
    match net with
    | Some n -> Some n
    | None -> Eio_context.get_net_opt ()
  in
  match sw, net with
  | Some sw, Some net -> Ok (sw, net)
  | None, _ -> Error "Eio switch not available (running outside server context)"
  | _, None -> Error "Eio net not available (running outside server context)"

let eio_context_error_to_sdk_error detail =
  Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field = "eio_context"; detail })

let cascade_catalog_error_to_sdk_error detail =
  Agent_sdk.Error.Config
    (Agent_sdk.Error.InvalidConfig { field = "cascade_name"; detail })

let keeper_agent_name_opt (keeper_name : string) =
  let keeper_name = String.trim keeper_name in
  if keeper_name = "" then None else Some (Keeper_identity.keeper_agent_name keeper_name)

let runtime_mcp_policy_for_tools ~(keeper_name : string) (tools : Agent_sdk.Tool.t list) =
  let agent_name = keeper_agent_name_opt keeper_name in
  let runtime_tool_names =
    tools
    |> List.filter (fun (tool : Agent_sdk.Tool.t) ->
      Tool_catalog.is_public_mcp tool.schema.name
      || (Option.is_some agent_name
          && Tool_catalog.is_on_surface Tool_catalog.Keeper_internal tool.schema.name))
    |> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name)
  in
  let has_keeper_internal =
    List.exists
      (Tool_catalog.is_on_surface Tool_catalog.Keeper_internal)
      runtime_tool_names
  in
  match
    ( Runtime_agent.runtime_mcp_policy_of_tool_names
        ?agent_name
        ~allow_keeper_internal:has_keeper_internal
        runtime_tool_names
    , agent_name )
  with
  | Some policy, Some agent_name ->
    Some (Runtime_agent.runtime_mcp_policy_with_masc_agent_name ~agent_name policy)
  | Some policy, None -> Some policy
  | None, _ -> None

let keeper_internal_tool_names_for_runtime_surface
      ~(keeper_name : string)
      (tools : Agent_sdk.Tool.t list)
  =
  match keeper_agent_name_opt keeper_name with
  | None -> []
  | Some _ ->
    tools
    |> List.filter (fun (tool : Agent_sdk.Tool.t) ->
      Tool_catalog.is_on_surface Tool_catalog.Keeper_internal tool.schema.name)
    |> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name)
    |> List.sort_uniq String.compare

let keeper_internal_tools_require_materialized_runtime_surface
      ~(keeper_name : string)
      (tools : Agent_sdk.Tool.t list)
  =
  keeper_internal_tool_names_for_runtime_surface ~keeper_name tools <> []

let runtime_mcp_policy_for_provider
      ~(keeper_name : string)
      ~(provider_cfg : Llm_provider.Provider_config.t)
      (policy_opt : Llm_provider.Llm_transport.runtime_mcp_policy option)
  =
  let agent_name = keeper_agent_name_opt keeper_name |> Option.value ~default:"" in
  Runtime_agent.runtime_mcp_policy_for_provider ~provider_cfg ~agent_name policy_opt

let cli_tool_a_cannot_carry_keeper_bound_runtime_mcp
      ~(keeper_name : string)
      ~(provider_cfg : Llm_provider.Provider_config.t)
      (policy_opt : Llm_provider.Llm_transport.runtime_mcp_policy option)
  =
  (* RFC-0058 §2.4: dispatch by local tool-delivery policy, not provider name. *)
  if
    not
      (Provider_tool_support
       .provider_requires_per_keeper_bridging_for_bound_actor_tools
         provider_cfg)
  then false
  else (
    match keeper_agent_name_opt keeper_name, policy_opt with
    | Some agent_name, Some policy
      when Option.is_some (Keeper_identity.keeper_name_from_agent_name agent_name) ->
      (not
         (Runtime_agent.cli_tool_a_can_auth_keeper_bound_runtime_mcp ~agent_name policy))
      && List.exists
           Runtime_agent.runtime_mcp_tool_requires_bound_actor
           policy.allowed_tool_names
    | _ -> false)
