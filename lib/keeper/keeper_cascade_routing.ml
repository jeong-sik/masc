(** State-aware cascade profile selection.

    Maps keeper phase to an effective cascade profile name.
    Pure function — mirrors TLA+ KeeperCoreTriad.SelectCascade action.
    The live keeper-turn hot path phase-gates non-executable phases before
    provider dispatch; those branches are retained for diagnostics/spec parity
    and must not imply that a new provider turn will run while paused,
    draining, overflowed, compacting, or handing off.

    @since Core Triad (State x Decision x Cascade) *)

type routing_decision = {
  effective_cascade : string;
  reason : string;
}

let select_cascade ~(base_cascade : string) ~(phase : Keeper_state_machine.phase)
    : routing_decision =
  let decision =
    match phase with
    | Running ->
        { effective_cascade = base_cascade;
          reason = "healthy, using configured cascade" }
    | Failing ->
        { effective_cascade = Keeper_config.local_recovery_cascade_name;
          reason = "failing phase: cheap local recovery" }
    | Compacting | HandingOff ->
        { effective_cascade = Keeper_config.local_only_cascade_name;
          reason = "buffer operation: diagnostic route; hot path blocks new turns" }
    | Overflowed ->
        { effective_cascade = base_cascade;
          reason = "overflowed phase: turn blocked upstream pending compaction" }
    | Draining | Paused ->
        { effective_cascade = base_cascade;
          reason = "non-executable phase: turn blocked upstream" }
    | Offline | Stopped | Dead | Zombie | Crashed | Restarting ->
        { effective_cascade = base_cascade;
          reason = "non-turn phase (blocked upstream)" }
  in
  if not (String.equal decision.effective_cascade base_cascade) then
    Cascade_metrics.on_phase_override
      ~phase:(Keeper_state_machine.phase_to_string phase)
      ~from_cascade:base_cascade
      ~to_cascade:decision.effective_cascade;
  decision

let route_effective_cascade_for_tool_requirement
    ~(effective_cascade : string) ~(tool_requirement : Keeper_agent_tool_surface.tool_requirement) :
    routing_decision =
  match tool_requirement with
  | Required ->
    {
      effective_cascade;
      reason =
        "tool-required turn keeps routed cascade; provider capability filter enforces tool support";
    }
  | Optional | No_tools ->
    {
      effective_cascade;
      reason = "tool-optional or text-only turn keeps routed cascade";
    }
