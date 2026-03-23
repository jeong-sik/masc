(** Mcp_server_eio_types -- Shared types for MCP server modules

    Extracted from mcp_server_eio.ml to avoid circular dependencies.
*)

type tool_profile =
  | Full
  | Managed_agent
  | Operator_remote
