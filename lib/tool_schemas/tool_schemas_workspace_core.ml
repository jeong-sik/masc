(** MCP tool schemas for workspace management operations (core).

    Only schemas dispatched by Tool_workspace remain here.
    Other schemas live in their owning modules. *)

open Masc_domain

let schemas : tool_schema list = [
  Tool_schemas_workspace_core_toml.status;
  Tool_schemas_workspace_core_toml.check;

  Tool_schemas_workspace_core_toml.heartbeat;
]
