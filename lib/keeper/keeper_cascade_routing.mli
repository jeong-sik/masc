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
    - Running      -> [base_cascade]    (healthy, full capability)
    - Failing      -> ["local_recovery"] (cheap local model for recovery)
    - Compacting   -> ["local_only"]     (local model sufficient)
    - Other phases -> [base_cascade]     (default, turn may be blocked upstream) *)
val select_cascade :
  base_cascade:string ->
  phase:Keeper_state_machine.phase ->
  routing_decision
