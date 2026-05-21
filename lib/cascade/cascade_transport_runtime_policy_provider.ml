(** Provider-driven runtime MCP policy resolver + CLI JSON merger,
    extracted from [cascade_transport.ml] (godfile decomp). Two
    helpers:

    - [runtime_mcp_policy_for_provider] — RFC-0058 §2.4 dispatch by
      local tool-delivery policy ([requires_per_keeper_bridging]),
      not by provider name. Resolves the policy through one of four
      branches based on the (policy, bridging_required, agent_name)
      triple. Tracks legacy strip-all path via
      [Cascade_metrics.on_runtime_mcp_legacy_strip].

    - [cli_runtime_mcp_jsons] — merges a [~base] list of MCP JSON
      strings with the [cli_mcp_config_json_of_policy] projection of
      a runtime MCP policy, deduping while preserving the original
      order. *)

module Mcp_policy_helpers = Cascade_transport_mcp_policy_helpers
module Auth_bridging = Cascade_transport_auth_bridging
module Cli_mcp_config_json = Cascade_transport_cli_mcp_config_json

(* Duplicated locally to avoid sibling -> parent cycle. The parent
   keeps its own copy because three other sites there call it; both
   copies are identical 11-line list-dedup helpers. *)
let dedupe_preserve_order (items : string list) =
  let seen = Hashtbl.create (List.length items) in
  List.filter
    (fun item ->
       if Hashtbl.mem seen item
       then false
       else (
         Hashtbl.add seen item ();
         true))
    items
;;

let runtime_mcp_policy_for_provider
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
    Some (Auth_bridging.bridged_runtime_mcp_policy_for_agent ~agent_name policy)
  | Some policy, true, None ->
    (* No agent_name to inject — preserve the legacy strip-all behavior.
       Iter 38: tick a counter so a non-zero rate flags caller paths
       that should be threading [agent_name] but aren't.  Strip-all
       means auth-bearing headers (e.g. Authorization: Bearer ...)
       disappear and runtime MCP tools run unauthenticated. *)
    Cascade_metrics.on_runtime_mcp_legacy_strip ();
    Some (Mcp_policy_helpers.runtime_mcp_policy_without_http_headers policy)
  | Some policy, false, Some agent_name ->
    Some (Mcp_policy_helpers.runtime_mcp_policy_with_masc_agent_name ~agent_name policy)
  | Some policy, false, None -> Some policy
  | None, _, _ -> None
;;

let cli_runtime_mcp_jsons
      ~(base : string list)
      (policy_opt : Llm_provider.Llm_transport.runtime_mcp_policy option)
  =
  let request_json =
    match policy_opt with
    | Some policy -> Option.to_list (Cli_mcp_config_json.cli_mcp_config_json_of_policy policy)
    | None -> []
  in
  dedupe_preserve_order (base @ request_json)
;;

