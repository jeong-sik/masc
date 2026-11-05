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

(** The name a profile has in telemetry, error messages and the persisted
    session file: [full], [managed_agent], [operator_remote], [seat]. *)
val tool_profile_to_string : tool_profile -> string

(** The profile named by [tool_profile_to_string]; [None] for any other string. *)
val tool_profile_of_string : string -> tool_profile option
