(** Agent registry status and capability queries.

    Reads from [Workspace_state] / [Workspace_utils] and renders the result
    as a [Yojson.Safe.t] document for the MCP resource handlers and
    the [tool_agent] tool. *)

open Masc_domain
include module type of Workspace_utils
include module type of Workspace_state

(* Agent-status surface removed (2026-06-09): the disk-backed `.masc/agents/`
   registry producer ([Workspace_eio.register_agent]) had zero call sites, so
   every read here returned empty for ~12 days (the retired dashboard judge produced 0
   judgments). Live agent status is served by the in-memory session registry
   ([Session.get_agent_statuses], exposed via the `who` resource). Removed:
   get_agents_status / register_capabilities / update_agent_r /
   find_agents_by_capability. See PR body for the producer-death analysis. *)
