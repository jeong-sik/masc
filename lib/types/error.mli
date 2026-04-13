(** Centralized error types for masc-mcp

    Provides structured error types to replace string-based errors.

    @since 0.4.0
*)

(** {1 Domain-Specific Errors} *)

(** Room/Coordination errors *)
type room_error =
  | RoomNotFound of string
  | RoomAlreadyExists of string
  | RoomLocked of string
  | RoomFull of int

(** Task errors *)
type task_error =
  | TaskNotFound of string
  | TaskAlreadyClaimed of string
  | TaskInvalidState of string * string
  | TaskCycleDetected

(** Agent errors *)
type agent_error =
  | AgentNotFound of string
  | AgentTimeout of string * int
  | AgentHeartbeatMissing of string
  | AgentCapabilityMismatch of string

(** Federation/Portal errors *)
type federation_error =
  | PortalConnectionFailed of string
  | PortalAuthFailed of string
  | PortalTimeout of int
  | PortalProtocolError of string

(** Storage/Backend errors *)
type storage_error =
  | FileNotFound of string
  | FilePermissionDenied of string
  | FileLocked of string
  | GitError of string

(** MCP Protocol errors *)
type mcp_error =
  | McpParseError of string
  | McpMethodNotFound of string
  | McpInvalidParams of string
  | McpAuthError of string
  | McpInternalError of string

(** {1 Unified Error Type} *)

(** Top-level error type combining all domains *)
type t =
  | Room of room_error
  | Task of task_error
  | Agent of agent_error
  | Federation of federation_error
  | Storage of storage_error
  | Mcp of mcp_error
  | Internal of string

(** {1 Error Utilities} *)

val is_recoverable : t -> bool
(** Check if an error is recoverable (safe to retry). *)

val to_string : t -> string
(** Get a human-readable error message. *)

(** {1 Result Helpers} *)

type 'a result = ('a, t) Stdlib.result
(** Shorthand for error result type. *)

val fail : t -> ('a, t) Stdlib.result
(** Create an error result. *)

val ok : 'a -> ('a, t) Stdlib.result
(** Create a success result. *)

val to_string_result : ('a, t) Stdlib.result -> ('a, string) Stdlib.result
(** Map error to string for legacy compatibility. *)

val of_string : string -> t
(** Convert string error to Internal error (for migration). *)

(** {1 Logging Integration} *)

type severity = Debug | Info | Warning | Error | Critical

val severity_of_error : t -> severity
(** Get error severity level. *)

val string_of_severity : severity -> string

val to_severity : severity -> Severity.t
(** Coerce to canonical {!Severity.t} for cross-module communication. *)

(** {1 Migration Bridge} *)

val to_masc_error : t -> Types_auth.masc_error
(** Convert [Error.t] to [Types_auth.masc_error] for migration.
    @since 2.104.0 *)
