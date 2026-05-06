(** Bulkhead-isolated cascade pool.

    A pool is a self-contained set of providers with its own health
    tracker and selection state.  Pools are isolated: a provider
    failure in one pool does not affect another pool's health state.

    @since Phase 1 — Resilience Architecture *)

(** {1 Pool Identity} *)

type pool_id =
  | Tier1 (** High-trust cloud providers: GLM, Kimi, Claude, Gemini, etc. *)
  | Tier2 (** Local / lower-trust: Ollama, local models *)
  | Emergency (** Static fallback: no LLM call, deterministic response *)

val pool_id_to_string : pool_id -> string
val pool_id_of_string : string -> pool_id option

(** {1 Pool State} *)

(** Opaque pool state. *)
type t

(** Create a new pool with the given providers.

    Each pool owns a dedicated {!Cascade_health_tracker.t} so health
    state is isolated from other pools.

    @raise Invalid_argument when [provider_keys] is empty. *)
val create : pool_id -> provider_keys:string list -> t

(** The pool's identifier. *)
val id : t -> pool_id

(** Provider keys belonging to this pool. *)
val provider_keys : t -> string list

(** Per-pool health tracker.  Isolated from other pools. *)
val health_tracker : t -> Cascade_health_tracker.t

(** Whether every provider in the pool is in cooldown. *)
val all_in_cooldown : t -> bool

(** Human-readable summary for observability. *)
val summary : t -> string
