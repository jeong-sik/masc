(** State-aware cascade profile selection.

    Maps keeper phase to an effective cascade profile name. The keeper's
    base cascade (from persona/team config) is overridden when the current
    phase calls for a cheaper or faster model.

    Pure function — mirrors TLA+ KeeperCoreTriad.SelectCascade action.

    @since Core Triad (State x Decision x Cascade) *)

(** Result of cascade routing decision. *)
type routing_decision = {
  effective_cascade : string;
  reason : string;
}

(** Select the effective cascade profile for the current turn.

    [~base_cascade] is the keeper's configured cascade name
    (typically ["keeper_unified"]).

    Routing rules (TLA+ mirrored):
    - [Running], [Draining], [Paused] -> [base_cascade]
    - [Failing] -> ["local_recovery"]
    - [Compacting], [HandingOff] -> ["local_only"]
    - [Overflowed], terminal/non-executable phases -> [base_cascade]

    This helper is total: even phases that are blocked upstream still return
    a routing decision so dashboards/tests can inspect the same contract.
    The keeper cycle gate remains the owner of "can this phase execute a turn?" *)
val select_cascade :
  base_cascade:string ->
  phase:Keeper_state_machine.phase ->
  routing_decision

(** Override an already-routed cascade when the turn must guarantee a
    tool-capable provider lane. Phase-routed local/recovery cascades are
    preserved. *)
val route_effective_cascade_for_tool_requirement :
  effective_cascade:string ->
  tool_requirement:string ->
  routing_decision
