(** Unified error type for MASC MCP *)

include module type of Rate_limit_types

val default_rate_limit : rate_limit_config
val rate_limit_config_to_yojson : rate_limit_config -> Yojson.Safe.t
val rate_limit_config_of_yojson : Yojson.Safe.t -> (rate_limit_config, string) result
val show_rate_limit_category : rate_limit_category -> string
val show_rate_limit_error : rate_limit_error -> string
val limit_for_category : rate_limit_config -> rate_limit_category -> int
val category_for_tool : string -> rate_limit_category
val category_for_tool_opt : string -> rate_limit_category option

type cache_error =
  | CacheReadFailed of string
  | CacheWriteFailed of string
  | CacheExpired of { key: string; age_hours: float }
  | CacheCorrupted of string

module Task_error : sig
  type t =
    | NotFound of string
    | AlreadyClaimed of { task_id: string; by: string }
    | NotClaimed of string
    | InvalidState of string
    | InvalidId of string
  val to_string : t -> string
end

module Agent_error : sig
  type t =
    | NotFound of string
    | NotJoined of string
    | AlreadyJoined of string
    | InvalidName of string
  val to_string : t -> string
end

module Auth_error : sig
  type t =
    | Unauthorized of string
    | Forbidden of { agent: string; action: string }
    | TokenExpired of string
    | InvalidToken of string
  val to_string : t -> string
end

module Portal_error : sig
  type t =
    | NotOpen of string
    | AlreadyOpen of { agent: string; target: string }
    | Closed of string
  val to_string : t -> string
end

module System_error : sig
  type t =
    | NotInitialized
    | AlreadyInitialized
    | InvalidJson of string
    | IoError of string
    | InvalidFilePath of string
    | StorageError of string
    | ValidationError of string
  val to_string : t -> string
end

type t =
  | Task of Task_error.t
  | Agent of Agent_error.t
  | Auth of Auth_error.t
  | Portal of Portal_error.t
  | System of System_error.t
  | RateLimitExceeded of rate_limit_error
  | CacheError of cache_error

val to_string : t -> string
val show : t -> string
val to_yojson : t -> Yojson.Safe.t
val code : t -> int
