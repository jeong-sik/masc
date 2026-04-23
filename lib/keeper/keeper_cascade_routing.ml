(** State-aware cascade profile selection.

    Maps keeper phase to an effective cascade profile name.
    Pure function — mirrors TLA+ KeeperCoreTriad.SelectCascade action.

    @since Core Triad (State x Decision x Cascade) *)

type routing_decision = {
  effective_cascade : string;
  reason : string;
}

let select_cascade ~(base_cascade : string) ~(phase : Keeper_state_machine.phase)
    : routing_decision =
  match phase with
  | Running ->
      { effective_cascade = base_cascade;
        reason = "healthy, using configured cascade" }
  | Failing ->
      { effective_cascade = Keeper_config.local_recovery_cascade_name;
        reason = "failing phase: cheap local recovery" }
  | Compacting | HandingOff ->
      { effective_cascade = Keeper_config.local_only_cascade_name;
        reason = "buffer operation: local model sufficient" }
  | Overflowed ->
      { effective_cascade = base_cascade;
        reason = "overflowed phase: turn blocked upstream pending compaction" }
  | Draining | Paused ->
      { effective_cascade = base_cascade;
        reason = "winding down: complete in-progress work" }
  | Offline | Stopped | Dead | Crashed | Restarting ->
      { effective_cascade = base_cascade;
        reason = "non-turn phase (blocked upstream)" }

let route_effective_cascade_for_tool_requirement
    ~(effective_cascade : string)
    ~(tool_requirement : string) : routing_decision =
  let trimmed_effective = String.trim effective_cascade in
  let normalized_effective =
    Keeper_cascade_profile.normalize_declared_name trimmed_effective
  in
  if not (String.equal tool_requirement "required") then
    {
      effective_cascade;
      reason = "tool-optional or text-only turn keeps routed cascade";
    }
  else if
    String.equal trimmed_effective Keeper_config.tool_use_strict_cascade_name
    || String.equal normalized_effective Keeper_config.local_only_cascade_name
    || String.equal normalized_effective Keeper_config.local_recovery_cascade_name
  then
    {
      effective_cascade;
      reason = "tool-required turn preserves phase-routed system cascade";
    }
  else
    {
      effective_cascade = Keeper_config.tool_use_strict_cascade_name;
      reason = "tool-required turn uses strict tool-capable cascade";
    }
