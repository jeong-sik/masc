(** Pool router — maps keepers to pools and handles pool-level fallback.

    Implements the Bulkhead pattern: each keeper is assigned to a
    primary pool.  When the primary pool is fully in cooldown, the
    router falls through to lower tiers (Tier1 → Tier2 → Emergency).

    @since Phase 1 — Resilience Architecture *)

type t

(** Create a router from the global cascade configuration.

    Reads pool assignments from [cascade.json] or environment overrides. *)
val create : unit -> t

(** Resolve the primary pool for a keeper. *)
val resolve_pool : t -> keeper_name:string -> Cascade_pool.pool_id

(** Execute a provider call with automatic pool fallback.

    [f] is called with a provider key selected from the primary pool.
    If the primary pool's providers are all in cooldown, falls through
    to the next tier.  Returns [Error `All_pools_exhausted] only when
    all pools including Emergency have been exhausted. *)
val execute_with_fallback
  :  t
  -> keeper_name:string
  -> (provider_key:string -> ('a, 'e) result)
  -> ('a, [> `All_pools_exhausted of string list ]) result

(** All registered pools. *)
val pools : t -> Cascade_pool.t list

module For_testing : sig
  val parse_provider_list_value : default:string list -> string option -> string list

  val create_from_provider_keys
    :  tier1_keys:string list
    -> tier2_keys:string list
    -> emergency_keys:string list
    -> t
end
