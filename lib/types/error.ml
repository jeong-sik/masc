(** Centralized error types for masc-mcp

    @deprecated Prefer [Types_auth.masc_error] which is the canonical
    error type used across the codebase (72+ call sites). This module
    has only 18 call sites and will be removed once they migrate.

    Use {!to_masc_error} to bridge from [Error.t] to [masc_error]
    during the migration period.

    @since 0.4.0
*)

(** {1 Domain-Specific Errors} *)

(** Coord/Coordination errors *)
type room_error =
  | RoomNotFound of string         (** Coord doesn't exist *)
  | RoomAlreadyExists of string    (** Duplicate room creation *)
  | RoomLocked of string           (** Coord is locked by another agent *)
  | RoomFull of int                (** Max agents reached *)

(** Task errors *)
type task_error =
  | TaskNotFound of string         (** Task doesn't exist *)
  | TaskAlreadyClaimed of string   (** Task owned by another agent *)
  | TaskInvalidState of string * string  (** Current state, expected state *)
  | TaskCycleDetected              (** Dependency cycle *)

(** Agent errors *)
type agent_error =
  | AgentNotFound of string        (** Agent doesn't exist *)
  | AgentTimeout of string * int   (** Agent ID, timeout ms *)
  | AgentHeartbeatMissing of string  (** Agent stopped responding *)
  | AgentCapabilityMismatch of string  (** Required capability not found *)

(** Federation/Portal errors *)
type federation_error =
  | PortalConnectionFailed of string  (** Target address *)
  | PortalAuthFailed of string        (** Reason *)
  | PortalTimeout of int              (** Timeout ms *)
  | PortalProtocolError of string     (** Protocol mismatch *)

(** Storage/Backend errors *)
type storage_error =
  | FileNotFound of string
  | FilePermissionDenied of string
  | FileLocked of string
  | GitError of string

(** MCP Protocol errors *)
type mcp_error =
  | McpParseError of string         (** Invalid JSON-RPC *)
  | McpMethodNotFound of string     (** Unknown method *)
  | McpInvalidParams of string      (** Invalid parameters *)
  | McpAuthError of string          (** Authentication failed *)
  | McpInternalError of string      (** Internal server error *)

(** {1 Unified Error Type} *)

(** Top-level error type combining all domains *)
type t =
  | Coord of room_error
  | Task of task_error
  | Agent of agent_error
  | Federation of federation_error
  | Storage of storage_error
  | Mcp of mcp_error
  | Internal of string              (** Unexpected internal error *)

(** {1 Error Utilities} *)

(** Check if an error is recoverable (safe to retry) *)
let is_recoverable = function
  | Coord (RoomNotFound _) -> false
  | Coord (RoomAlreadyExists _) -> false
  | Coord (RoomLocked _) -> true
  | Coord (RoomFull _) -> false
  | Task (TaskNotFound _) -> false
  | Task (TaskAlreadyClaimed _) -> true
  | Task (TaskInvalidState _) -> false
  | Task TaskCycleDetected -> false
  | Agent (AgentNotFound _) -> false
  | Agent (AgentTimeout _) -> true
  | Agent (AgentHeartbeatMissing _) -> true
  | Agent (AgentCapabilityMismatch _) -> false
  | Federation (PortalConnectionFailed _) -> false
  | Federation (PortalAuthFailed _) -> false
  | Federation (PortalTimeout _) -> true
  | Federation (PortalProtocolError _) -> false
  | Storage (FileNotFound _) -> false
  | Storage (FilePermissionDenied _) -> false
  | Storage (FileLocked _) -> true
  | Storage (GitError _) -> false
  | Mcp (McpParseError _) -> false
  | Mcp (McpMethodNotFound _) -> false
  | Mcp (McpInvalidParams _) -> false
  | Mcp (McpAuthError _) -> false
  | Mcp (McpInternalError _) -> false
  | Internal _ -> false

(** Get a human-readable error message *)
let to_string = function
  | Coord e -> (
      match e with
      | RoomNotFound id -> Printf.sprintf "Coord not found: %s" id
      | RoomAlreadyExists id -> Printf.sprintf "Coord already exists: %s" id
      | RoomLocked id -> Printf.sprintf "Coord locked: %s" id
      | RoomFull max -> Printf.sprintf "Coord full (max %d agents)" max)
  | Task e -> (
      match e with
      | TaskNotFound id -> Printf.sprintf "Task not found: %s. Call masc_status to refresh your task list." id
      | TaskAlreadyClaimed owner -> Printf.sprintf "Task already claimed by: %s" owner
      | TaskInvalidState (current, expected) ->
          Printf.sprintf "Invalid task state: %s (expected %s)" current expected
      | TaskCycleDetected -> "Task dependency cycle detected")
  | Agent e -> (
      match e with
      | AgentNotFound id -> Printf.sprintf "Agent not found: %s" id
      | AgentTimeout (id, ms) -> Printf.sprintf "Agent %s timed out after %dms" id ms
      | AgentHeartbeatMissing id -> Printf.sprintf "Agent %s heartbeat missing" id
      | AgentCapabilityMismatch cap -> Printf.sprintf "No agent with capability: %s" cap)
  | Federation e -> (
      match e with
      | PortalConnectionFailed addr -> Printf.sprintf "Portal connection failed: %s" addr
      | PortalAuthFailed reason -> Printf.sprintf "Portal auth failed: %s" reason
      | PortalTimeout ms -> Printf.sprintf "Portal timeout after %dms" ms
      | PortalProtocolError msg -> Printf.sprintf "Portal protocol error: %s" msg)
  | Storage e -> (
      match e with
      | FileNotFound path -> Printf.sprintf "File not found: %s" path
      | FilePermissionDenied path -> Printf.sprintf "Permission denied: %s" path
      | FileLocked path -> Printf.sprintf "File locked: %s" path
      | GitError msg -> Printf.sprintf "Git error: %s" msg)
  | Mcp e -> (
      match e with
      | McpParseError msg -> Printf.sprintf "MCP parse error: %s" msg
      | McpMethodNotFound method_name -> Printf.sprintf "MCP method not found: %s" method_name
      | McpInvalidParams msg -> Printf.sprintf "MCP invalid params: %s" msg
      | McpAuthError msg -> Printf.sprintf "MCP auth error: %s" msg
      | McpInternalError msg -> Printf.sprintf "MCP internal error: %s" msg)
  | Internal msg -> Printf.sprintf "Internal error: %s" msg

(** {1 Result Helpers} *)

(** Shorthand for error result type *)
type 'a result = ('a, t) Stdlib.result

(** Create an error result *)
let fail e = Error e

(** Create a success result *)
let ok v = Ok v

(** Map error to string for legacy compatibility *)
let to_string_result = function
  | Ok v -> Ok v
  | Error e -> Error (to_string e)

(** Convert string error to Internal error (for migration) *)
let of_string msg = Internal msg

(** {1 Logging Integration} *)

(** Get error severity level *)
type severity = Debug | Info | Warning | Error | Critical

let severity_of_error = function
  | Coord (RoomLocked _) -> Warning
  | Task (TaskAlreadyClaimed _) -> Warning
  | Agent (AgentTimeout _) -> Warning
  | Agent (AgentHeartbeatMissing _) -> Warning
  | Federation (PortalTimeout _) -> Warning
  | Storage (FileLocked _) -> Warning
  | Mcp (McpMethodNotFound _) -> Warning
  | Internal _ -> Critical
  | Coord (RoomNotFound _) -> Error
  | Coord (RoomAlreadyExists _) -> Error
  | Coord (RoomFull _) -> Error
  | Task (TaskNotFound _) -> Error
  | Task (TaskInvalidState _) -> Error
  | Task TaskCycleDetected -> Error
  | Agent (AgentNotFound _) -> Error
  | Agent (AgentCapabilityMismatch _) -> Error
  | Federation (PortalConnectionFailed _) -> Error
  | Federation (PortalAuthFailed _) -> Error
  | Federation (PortalProtocolError _) -> Error
  | Storage (FileNotFound _) -> Error
  | Storage (FilePermissionDenied _) -> Error
  | Storage (GitError _) -> Error
  | Mcp (McpParseError _) -> Error
  | Mcp (McpInvalidParams _) -> Error
  | Mcp (McpAuthError _) -> Error
  | Mcp (McpInternalError _) -> Error

let string_of_severity = function
  | Debug -> "DEBUG"
  | Info -> "INFO"
  | Warning -> "WARN"
  | Error -> "ERROR"
  | Critical -> "CRITICAL"

(** Coerce to canonical [Severity.t] for cross-module communication. *)
let to_severity : severity -> Severity.t = function
  | Debug -> Debug
  | Info -> Info
  | Warning -> Warning
  | Error -> Error
  | Critical -> Critical

(** {1 Migration Bridge}

    Convert [Error.t] to [Types_auth.masc_error] for incremental
    migration to the canonical error type. *)

let to_masc_error : t -> Types_auth.masc_error = function
  | Coord (RoomNotFound id) -> Types_auth.IoError ("room not found: " ^ id)
  | Coord (RoomAlreadyExists id) -> Types_auth.IoError ("room exists: " ^ id)
  | Coord (RoomLocked id) -> Types_auth.IoError ("room locked: " ^ id)
  | Coord (RoomFull _) -> Types_auth.IoError "room full"
  | Task (TaskNotFound id) -> Types_auth.TaskNotFound id
  | Task (TaskAlreadyClaimed by) -> Types_auth.TaskAlreadyClaimed { task_id = ""; by }
  | Task (TaskInvalidState (current, _expected)) -> Types_auth.TaskInvalidState current
  | Task TaskCycleDetected -> Types_auth.TaskInvalidState "cycle detected"
  | Agent (AgentNotFound id) -> Types_auth.AgentNotFound id
  | Agent (AgentTimeout (id, _ms)) -> Types_auth.IoError ("agent timeout: " ^ id)
  | Agent (AgentHeartbeatMissing id) -> Types_auth.IoError ("heartbeat missing: " ^ id)
  | Agent (AgentCapabilityMismatch cap) -> Types_auth.IoError ("capability mismatch: " ^ cap)
  | Federation (PortalConnectionFailed addr) -> Types_auth.IoError ("portal failed: " ^ addr)
  | Federation (PortalAuthFailed reason) -> Types_auth.Unauthorized reason
  | Federation (PortalTimeout _ms) -> Types_auth.IoError "portal timeout"
  | Federation (PortalProtocolError msg) -> Types_auth.IoError ("portal protocol: " ^ msg)
  | Storage (FileNotFound path) -> Types_auth.StorageError ("file not found: " ^ path)
  | Storage (FilePermissionDenied path) -> Types_auth.StorageError ("permission denied: " ^ path)
  | Storage (FileLocked path) -> Types_auth.StorageError ("file locked: " ^ path)
  | Storage (GitError msg) -> Types_auth.StorageError ("git: " ^ msg)
  | Mcp (McpParseError msg) -> Types_auth.InvalidJson msg
  | Mcp (McpMethodNotFound name) -> Types_auth.IoError ("method not found: " ^ name)
  | Mcp (McpInvalidParams msg) -> Types_auth.ValidationError msg
  | Mcp (McpAuthError msg) -> Types_auth.Unauthorized msg
  | Mcp (McpInternalError msg) -> Types_auth.IoError msg
  | Internal msg -> Types_auth.IoError msg
