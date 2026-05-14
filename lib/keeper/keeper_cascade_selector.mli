(** Keeper_cascade_selector — L1 Proactive Routing (RFC-0041 Phase B3).

    Per-turn item selection before dispatch. Selects the healthiest
    available cascade item following group strategy and fallback chains. *)

(** [select_item_for_turn ~keeper_name ~cascade_profile ~health_cache ~last_used_item]
    selects an item for the current turn.

    - Orders items within the group according to strategy.
    - Skips unhealthy items (per-item health cache).
    - Follows fallback_group chain when a group is fully unhealthy.
    - Detects cycles in fallback chain.

    Returns [Error `No_available_item] when all groups are exhausted.

    [last_used_item] is used by RoundRobin to advance the cursor.
    [health_cache] parameter is accepted for interface consistency;
    the actual health state is read from [Keeper_health_probe]. *)
val select_item_for_turn :
  keeper_name:string ->
  cascade_profile:Cascade_ref.cascade_profile ->
  health_cache:Keeper_health_probe.health_status ->
  last_used_item:string option ->
  cascade_ref:Cascade_ref.cascade_ref option ->
  (string * Cascade_ref.cascade_item, [> `No_available_item ]) result
(** Returns [(group_name, item)] so callers can route subsequent
    [meta.cascade_name] to the correct group.  PR #14266 originally
    returned just [cascade_item], but [Cascade_ref.cascade_item] has no
    [group] field — the caller in [Keeper_unified_turn] tried
    [item.Cascade_ref.group] which fails to type-check.  Carrying the
    [group_name] alongside the item lets the caller perform the
    intended override without depending on a non-existent field. *)
