(** Per-keeper authorization bridging for runtime MCP policies.
    Extracted from [runtime_transport.ml] (godfile decomp). Two
    helpers:

    - [codex_cli_can_auth_keeper_bound_runtime_mcp] — typed capability check
      for minting a verified per-keeper Authorization header.

    - [bridged_runtime_mcp_policy_for_agent] — the RFC-0058 §2.4
      capability-driven projection: strip inbound HTTP headers,
      re-inject MASC identity headers, and resolve Authorization from the
      exact bound-actor credential. *)

module Authorization = Runtime_transport_authorization
module Mcp_policy_helpers = Runtime_transport_mcp_policy_helpers

let codex_cli_can_auth_keeper_bound_runtime_mcp ~base_path ~agent_name policy =
  if not (Authorization.runtime_mcp_policy_uses_bound_actor_tools policy)
  then Ok false
  else
    Authorization.per_keeper_authorization_header ~base_path ~agent_name
    |> Result.map (fun _ -> true)
;;

(* RFC-0058 §2.4 capability-driven projection.

   Header lifecycle (in this order, no early exits):
   1. [runtime_mcp_policy_without_http_headers] strips ALL HTTP headers
      from every [Http_server] in the policy. This step is
      unconditional — any inbound [Authorization] is gone before any
      decision below.
   2. [runtime_mcp_policy_with_masc_agent_name] re-injects only the
      non-secret MASC identity headers.
   3. The [Authorization] header is resolved again from the exact per-agent
      credential via [Auth_resolve]. The inbound policy's bearer is never
      trusted as proof and an auth failure returns [Error]; a headerless policy
      is never produced.

   Invariant: this function is only reached from the dispatch site when the
   provider-tool policy says per-keeper bridging is required, i.e. the runtime
   cannot carry arbitrary per-request HTTP headers.  Body is intentionally
   identical in semantics to the prior client-named projection — the rename
   removes the provider-name leak from the dispatch site without altering
   behavior.

   A future adapter with [requires_per_keeper_bridging = true] but
   different transport semantics (e.g. native per-keeper header
   injection) should be handled by an explicit dispatch arm at the
   call site, not by adding a new flag parameter here — adding such
   a flag now would introduce a code path no current provider exercises
   and risks a silent header-preservation regression (see Copilot
   review of PR #14885). *)
let bridged_runtime_mcp_policy_for_agent ~base_path ~agent_name policy =
  let stripped =
    Mcp_policy_helpers.runtime_mcp_policy_without_http_headers policy
    |> Mcp_policy_helpers.runtime_mcp_policy_with_masc_agent_name
         ~agent_name
  in
  Authorization.per_keeper_authorization_header ~base_path ~agent_name
  |> Result.map (fun header ->
       Authorization.add_masc_authorization_header header stripped)
;;
