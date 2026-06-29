(** Provider-driven runtime MCP policy resolver, extracted from
    [runtime_transport.ml] (godfile decomp).

    - [runtime_mcp_policy_for_provider] — RFC-0058 §2.4 dispatch by
      local tool-delivery policy ([requires_per_keeper_bridging]),
      not by provider name. Resolves the policy through one of four
      branches based on the (policy, bridging_required, agent_name)
      triple. Missing [agent_name] with a provider that requires
      per-keeper bridging now fails closed instead of preserving an
      unauthenticated header-stripping path. *)

module Mcp_policy_helpers = Runtime_transport_mcp_policy_helpers
module Auth_bridging = Runtime_transport_auth_bridging

let runtime_mcp_policy_for_provider
      ~base_path
      ~(provider_cfg : Llm_provider.Provider_config.t)
      ~(agent_name : string)
      (policy_opt : Llm_provider.Llm_transport.runtime_mcp_policy option)
  =
  let agent_name =
    let trimmed = String.trim agent_name in
    if String.equal trimmed "" then None else Some trimmed
  in
  (* Dispatch by local tool-delivery policy, not by provider name
     (RFC-0058 §2.4).  [requires_per_keeper_bridging] gates the
     strip-and-bridge path. *)
  let requires_per_keeper_bridging =
    Provider_tool_support
    .provider_requires_per_keeper_bridging_for_bound_actor_tools
      provider_cfg
  in
  match policy_opt, requires_per_keeper_bridging, agent_name with
  | Some policy, true, Some agent_name ->
    (* Per-request HTTP headers are stripped and only MASC identity headers
         plus the per-keeper [Authorization] header survive — so runtime MCP
         tools still authenticate without leaking secrets via argv. *)
    Some (Auth_bridging.bridged_runtime_mcp_policy_for_agent ~base_path ~agent_name policy)
  | Some _policy, true, None ->
    (* No keeper identity means no safe per-keeper bridge. Returning
       [None] makes the caller either fall back to inline tools (when
       supported) or surface a tool-support error instead of running
       runtime MCP tools unauthenticated. *)
    None
  | Some policy, false, Some agent_name ->
    Some (Mcp_policy_helpers.runtime_mcp_policy_with_masc_agent_name ~agent_name policy)
  | Some policy, false, None -> Some policy
  | None, _, _ -> None
;;
