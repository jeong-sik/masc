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
val rate_from_env : unit -> float
val burst_from_env : unit -> int
val rate : t -> float
val burst : t -> int
val create : ?rate:float -> ?burst:int -> unit -> t
val create_from_env : unit -> t

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

(** {1 Automatic Cleanup Loop} *)

val start_cleanup_loop :
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> ?interval:float -> t -> unit

(** {1 HTTP Helpers} *)

val headers : t -> key:string -> (string * string) list
val too_many_requests_body : unit -> string
val headers_global : key:string -> (string * string) list

(** {1 Client Address Key Extraction} *)

val key_of_sockaddr : Eio.Net.Sockaddr.stream -> string

(** {1 Global Startup Helper} *)

val start_global_cleanup_loop : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> unit
