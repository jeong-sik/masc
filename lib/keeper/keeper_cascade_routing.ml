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
  (* cascade→Runtime 숙청: per-phase cascade override 제거. cascade 세계에서는
     Failing -> routes.phase_recovery, Compacting/HandingOff -> routes.phase_buffer
     로 갈렸지만, Runtime 모델에서는 binding 하나가 곧 하나의 Runtime 이고 모든
     phase 가 동일한 default Runtime 을 쓴다 (phase_recovery_cascade_name ==
     phase_buffer_cascade_name == get_default_runtime_id()). override 분기는 죽은
     추상화이므로 항등으로 collapse 한다. phase 는 reason 진단용으로만 유지하고,
     override 가 더 이상 없으므로 on_phase_override 텔레메트리도 제거한다. *)
  let reason =
    match phase with
    | Running -> "healthy, using configured runtime"
    | Failing | Compacting | HandingOff | Overflowed | Draining | Paused ->
        "single runtime: no per-phase cascade override"
    | Offline | Stopped | Dead | Zombie | Crashed | Restarting ->
        "non-turn phase (blocked upstream)"
  in
  { effective_cascade = base_cascade; reason }

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
