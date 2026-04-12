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
      { effective_cascade = "local_recovery";
        reason = "failing phase: cheap local recovery" }
  | Compacting | HandingOff ->
      { effective_cascade = "local_only";
        reason = "buffer operation: local model sufficient" }
  | Draining | Paused ->
      { effective_cascade = base_cascade;
        reason = "winding down: complete in-progress work" }
  | Offline | Stopped | Dead | Crashed | Restarting ->
      { effective_cascade = base_cascade;
        reason = "non-turn phase (blocked upstream)" }
