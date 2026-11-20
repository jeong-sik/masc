(** Mcp_server_eio_types — shared types for MCP server modules.

    Extracted from [mcp_server_eio.ml] to avoid circular dependencies. *)

(** Tool exposure profile for an MCP session. *)
type tool_profile =
  | Full
  | Managed_agent
  | Operator_remote
  | Seat
      (** An invited player at the shared machine: [/mcp/play], the tools
          that require [CanPlayMachine] and no other MCP method. *)

(** How a request reached the dispatcher, which decides by it whether the
    request may call a method that requires auth (RFC
    a-request-reads-its-bearer-once-at-the-door, D3).

    HIGH-RISK-UNREVIEWED: [Admitted] carries what a door read; the dispatcher
    does not read the bearer again for it. *)
type sender =
  | Admitted of Auth.request_principal
      (** A door ({!Auth.admit_request}) admitted the request: HTTP [/mcp]
          and stdio. *)
  | Unadmitted
      (** No door admitted the request, and it carries no bearer: a message
          on an upgraded WebSocket, whose [dashboard/hello] authenticates the
          session rather than its messages, or a test that calls the
          dispatcher directly. Public methods pass; the others need auth to
          be off, which the gate reads. *)

(** The name a profile has in telemetry, error messages and the persisted
    session file: [full], [managed_agent], [operator_remote], [seat]. *)
val tool_profile_to_string : tool_profile -> string

(** The profile named by [tool_profile_to_string]; [None] for any other string. *)
val tool_profile_of_string : string -> tool_profile option
