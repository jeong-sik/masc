(** Keeper_cascade_selector — L1 Proactive Routing (RFC-0041 Phase B3).

    Per-turn item selection before dispatch. Selects the healthiest
    available cascade item following group strategy and fallback chains. *)

(** Result of a successful item selection.

    Both the resolved [group] (after any fallback-chain traversal) and
    the chosen [item] are returned because RFC-0041 Phase B4 needs the
    group name to override [meta.cascade_name] for downstream cascade
    resolution; the bare [cascade_item] does not carry group context. *)
type selected_target = {
  group : string;
  item : Cascade_ref.cascade_item;
}

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
  (selected_target, [> `No_available_item ]) result
