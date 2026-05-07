(** Pool router — DEPRECATED, no call sites.  See {!Cascade_pool_router} body. *)

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
val execute_with_fallback :
  t ->
  keeper_name:string ->
  (provider_key:string -> ('a, 'e) result) ->
  ('a, [> `All_pools_exhausted of string list ]) result

(** All registered pools. *)
val pools : t -> Cascade_pool.t list
