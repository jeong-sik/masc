(** Rate Limiting for masc-mcp

    Provides token bucket rate limiting per client/agent.

    Configuration via environment:
    - MASC_RATE_LIMIT: requests per second (default: 60)
    - MASC_RATE_BURST: burst capacity (default: 150)

    @since 0.4.0 *)

(** {1 Types} *)

(** Opaque rate limiter instance. *)
type t

(** {1 Limiter Creation} *)

val default_rate : float
val default_burst : int
val default_agent_rate : float
(** Default per-agent requests per second: [20.0]. *)
val default_agent_burst : int
(** Default per-agent burst capacity: [50]. *)
val rate_of_config : unit -> float
val burst_of_config : unit -> int
val agent_rate_of_config : unit -> float
(** Per-agent rate from cached [MASC_AGENT_RATE_LIMIT] config (default [20.0]). *)
val agent_burst_of_config : unit -> int
(** Per-agent burst from cached [MASC_AGENT_RATE_BURST] config (default [50]). *)
val rate : t -> float
val burst : t -> int
val create : ?rate:float -> ?burst:int -> unit -> t
val create_of_config : unit -> t
val create_agent_of_config : unit -> t
(** Like [create_of_config] but uses the per-agent rate/burst config. *)

(** {1 Rate Checking} *)

(** [check limiter ~key] consumes one token for [key].
    Returns [true] if the request is allowed, [false] if rate limited. *)
val check : t -> key:string -> bool

(** [remaining limiter ~key] returns available tokens for [key]. *)
val remaining : t -> key:string -> int

(** {1 Cleanup} *)

(** Remove buckets not accessed in [older_than_seconds]. Returns count removed. *)
val cleanup : t -> older_than_seconds:int -> int

(** {1 Global Instance} *)

val global : t Eio.Lazy.t
val check_global : key:string -> bool
val remaining_global : key:string -> int

(** {1 Per-Agent Global Instance} *)

val agent_global : t Eio.Lazy.t
(** Lazy per-agent token-bucket limiter keyed by a provided Authorization bearer
    token or internal token-derived key. Separate from the per-IP limiter. *)

val check_agent_global : key:string -> bool
(** [check_agent_global ~key] consumes one per-agent token.
    Returns [true] if allowed, [false] if rate-limited. *)

val remaining_agent_global : key:string -> int
(** Available per-agent tokens for [key]. *)

val headers_agent_global : key:string -> (string * string) list
(** Rate-limit headers ([X-RateLimit-Limit] / [X-RateLimit-Remaining]) for
    the per-agent limiter at [key]. *)

(** {1 Automatic Cleanup Loop} *)

val start_cleanup_loop :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  ?label:string ->
  ?interval:float ->
  t ->
  unit

(** {1 HTTP Helpers} *)

val headers : t -> key:string -> (string * string) list
val too_many_requests_body : unit -> string
val too_many_agent_requests_body : unit -> string
(** JSON body for per-agent 429 responses. *)

(** Headers for a 429 response: [X-RateLimit-*] plus [Retry-After] (seconds). *)
val too_many_requests_headers : t -> key:string -> (string * string) list

val headers_global : key:string -> (string * string) list

(** {1 Client Address Key Extraction} *)

val key_of_sockaddr : Eio.Net.Sockaddr.stream -> string

(** {1 Agent Key Extraction} *)

val agent_key_of_token_or_name :
  ?token:string -> ?agent_name:string -> unit -> string option
(** Derive a per-agent rate-limit key from a bearer [token] (first 32 hex
    chars of its SHA-256, prefixed ["token:"]) or from [agent_name]
    (prefixed ["agent:"]).  [token] is tried first.  Returns [None] when
    neither is provided. *)

(** {1 Global Startup Helper} *)

val start_global_cleanup_loop : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> unit
(** Start cleanup loops for both the per-IP and per-agent global limiters.
    Call once at server startup. *)
