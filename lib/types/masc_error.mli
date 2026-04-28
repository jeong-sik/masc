(** Unified error type for MASC MCP *)

include module type of Rate_limit_types

val default_rate_limit : rate_limit_config
val rate_limit_config_to_yojson : rate_limit_config -> Yojson.Safe.t
val rate_limit_config_of_yojson : Yojson.Safe.t -> (rate_limit_config, string) result

val limit_for_category : rate_limit_config -> rate_limit_category -> int
val category_for_tool_opt : string -> rate_limit_category option
val category_for_tool : string -> rate_limit_category

type cache_error =
  | CacheReadFailed of string
  | CacheWriteFailed of string
  | CacheExpired of { key: string; age_hours: float }
  | CacheCorrupted of string

type t =
  | NotInitialized
  | AlreadyInitialized
  | AgentNotFound of string
  | AgentNotJoined of string
  | AgentAlreadyJoined of string
  | TaskNotFound of string
  | TaskAlreadyClaimed of { task_id: string; by: string }
  | TaskNotClaimed of string
  | TaskInvalidState of string
  | PortalNotOpen of string
  | PortalAlreadyOpen of { agent: string; target: string }
  | PortalClosed of string
  | InvalidJson of string
  | IoError of string
  | InvalidAgentName of string
  | InvalidTaskId of string
  | InvalidFilePath of string
  | Unauthorized of string
  | Forbidden of { agent: string; action: string }
  | TokenExpired of string
  | InvalidToken of string
  | RateLimitExceeded of rate_limit_error
  | CacheError of cache_error
  | StorageError of string
  | ValidationError of string

val to_string : t -> string
val show : t -> string
val to_yojson : t -> Yojson.Safe.t
val code : t -> int
