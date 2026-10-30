(** Mcp_server_eio_types — shared types for MCP server modules.

    Extracted from [mcp_server_eio.ml] to avoid circular dependencies. *)

(** Tool exposure profile for an MCP session. *)
type tool_profile =
  | Full
  | Managed_agent
  | Operator_remote
  | Seat
      (** An invited player at the shared machine (RFC
          play-link-for-the-shared-machine §2.7): [/mcp/play], the tools that
          require [CanPlayMachine] and no other MCP method. *)
