(** Rate Limiting for masc-mcp

    Provides token bucket rate limiting per client/agent.

    Configuration via environment:
    - MASC_RATE_LIMIT: requests per second (default: 60)
    - MASC_RATE_BURST: burst capacity (default: 150)

    @since 0.4.0 *)

(** {1 Types} *)

(** Opaque rate limiter instance. *)
type t

(** Product-facing agent quota tier. *)
type agent_quota_tier = Rate_limit_types.agent_quota_tier =
  | P0
  | P1
  | P2

(** Label-only quota-control term. *)
type agent_quota_control = Rate_limit_types.agent_quota_control =
  | LeaseExpiry
  | Backpressure
  | AdaptiveRate

(** Static operator contract for one quota tier. *)
type agent_quota_tier_contract =
  Rate_limit_types.agent_quota_tier_contract = {
  contract_tier : agent_quota_tier;
  code : string;
  label : string;
  workload_label : string;
  share_percent : int;
  default_req_per_min : int;
}

(** Computed request budget for one quota tier. *)
type agent_quota_allocation = Rate_limit_types.agent_quota_allocation = {
  allocation_tier : agent_quota_tier;
  allocation_percent : int;
  allocation_req_per_min : int;
}

(** {1 Limiter Creation} *)

val default_rate : float
val default_burst : int
val default_agent_rate : float
(** Default per-agent requests per second: [20.0]. *)
val default_agent_burst : int
(** Default per-agent burst capacity: [50]. *)
val rate_from_env : unit -> float
val burst_from_env : unit -> int
val agent_rate_from_env : unit -> float
(** Per-agent rate from [MASC_AGENT_RATE_LIMIT] env var (default [20.0]). *)
val agent_burst_from_env : unit -> int
(** Per-agent burst from [MASC_AGENT_RATE_BURST] env var (default [50]). *)
val rate : t -> float
val burst : t -> int
val create : ?rate:float -> ?burst:int -> unit -> t
val create_from_env : unit -> t
val create_agent_from_env : unit -> t
(** Like [create_from_env] but uses the per-agent rate/burst env vars. *)

(** {1 Agent Quota Tier Contract} *)

val default_agent_quota_total_per_min : int
(** Default Track9 operator budget: [1000] requests per minute. *)

val agent_quota_tiers : agent_quota_tier list
(** Stable tier order: P0, P1, P2. *)

val agent_quota_tier_code : agent_quota_tier -> string
(** ["P0"], ["P1"], or ["P2"]. *)

val agent_quota_tier_label : agent_quota_tier -> string
(** Operator-facing label, for example ["P0 Critical"]. *)

val agent_quota_tier_workload_label : agent_quota_tier -> string
(** Workload summary shown to operators. *)

val agent_quota_tier_share_percent : agent_quota_tier -> int
(** Target percentage of the total request budget. *)

val agent_quota_control_label : agent_quota_control -> string
(** Stable machine/display label for quota-control terms. *)

val agent_quota_control_labels : string list
(** Label-only controls: lease expiry, backpressure, adaptive rate. *)

val agent_quota_tier_contract : agent_quota_tier -> agent_quota_tier_contract
(** Static contract for [tier] using the default total request budget. *)

val agent_quota_tier_contracts : agent_quota_tier_contract list
(** Static contracts in {!agent_quota_tiers} order. *)

val agent_quota_tier_of_task_priority : int -> agent_quota_tier
(** Map current MASC task priority to quota tier:
    [priority <= 1] -> P0, [2..3] -> P1, [>= 4] -> P2. *)

val compute_agent_quota_allocations :
  total_req_per_min:int -> (agent_quota_allocation list, string) result
(** Compute P0/P1/P2 request budgets from [total_req_per_min].
    Positive totals are preserved exactly; rounding remainder is assigned
    deterministically in P0, P1, P2 order. *)

val validate_agent_quota_allocations :
  total_req_per_min:int -> agent_quota_allocation list -> (unit, string) result
(** Validate positive total, exact P0/P1/P2 coverage, non-negative
    allocation values, and sum preservation. *)

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
(** Lazy per-agent token-bucket limiter (separate from the per-IP limiter). *)

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
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> ?interval:float -> t -> unit

(** {1 HTTP Helpers} *)

val headers : t -> key:string -> (string * string) list
val too_many_requests_body : unit -> string
val too_many_agent_requests_body : unit -> string
(** JSON body for per-agent 429 responses. *)
val headers_global : key:string -> (string * string) list

(** {1 Client Address Key Extraction} *)

val key_of_sockaddr : Eio.Net.Sockaddr.stream -> string

(** {1 Agent Key Extraction} *)

val agent_key_of_token_or_name :
  ?token:string -> ?agent_name:string -> unit -> string option
(** Derive a per-agent rate-limit key from a bearer [token] (first 16 hex
    chars of its SHA-256, prefixed ["token:"]) or from [agent_name]
    (prefixed ["agent:"]).  [token] is tried first.  Returns [None] when
    neither is provided. *)

(** {1 Global Startup Helper} *)

val start_global_cleanup_loop : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> unit
(** Start cleanup loops for both the per-IP and per-agent global limiters.
    Call once at server startup. *)
