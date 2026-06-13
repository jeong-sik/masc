(** Unified error type for MASC MCP *)

include module type of Rate_limit_types

val default_rate_limit : rate_limit_config
val rate_limit_config_to_yojson : rate_limit_config -> Yojson.Safe.t
val rate_limit_config_of_yojson : Yojson.Safe.t -> (rate_limit_config, string) result
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
    | InvalidName of string
  val to_string : t -> string
end

module Auth_error : sig
  type unauthorized_reason =
    | Actor_mismatch
    | Missing_token
    | Generic
  type t =
    | Unauthorized of { reason: unauthorized_reason; message: string }
    | Forbidden of { agent: string; action: string }
    | TokenExpired of string
    | InvalidToken of string
  val unauthorized_reason_to_string : unauthorized_reason -> string
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
    | LockContention of { key : string; attempts : int }
      (** Distributed lock acquire budget exhausted under transient
          fleet contention.  Carries the structured key + attempt count
          so callers can dispatch on the typed variant instead of
          substring-matching the IoError message. *)
  val to_string : t -> string
end

type t =
  | Task of Task_error.t
  | Agent of Agent_error.t
  | Auth of Auth_error.t
  | System of System_error.t
  | RateLimitExceeded of rate_limit_error
  | CacheError of cache_error

val to_string : t -> string
val show : t -> string
val to_yojson : t -> Yojson.Safe.t
val code : t -> int

val is_retryable : t -> bool
(** [is_retryable err] — would replaying the same operation, without
    additional caller action, have a chance of succeeding?

    Mirrors the [Error.is_retryable] helper that OAS exposes on
    its [sdk_error]. Conservative: when in doubt the result is
    [false] so callers don't loop on deterministic failures.

    {ul
    {- [Task _], [Agent _]: [false] (domain-state
       errors — replaying changes nothing).}
    {- [Auth (TokenExpired _)]: [true] (clears once
       [masc_auth_refresh] runs); other [Auth] variants: [false].}
    {- [System (IoError _ | StorageError _)]: [true] (transient
       FS / backend); other [System] variants: [false]
       (caller-provided invariants).}
    {- [RateLimitExceeded _]: [true] (replays after the
       advertised wait).}
    {- [CacheError (CacheReadFailed _ | CacheWriteFailed _
       | CacheExpired _)]: [true]; [CacheCorrupted _]: [false]
       (persisted-data invariant violation).} } *)
