(** Phase-gate stage extracted from [Keeper_unified_turn.run_keeper_cycle]
    per RFC-0136 PR-1.

    Decides whether a keeper turn proceeds to runtime routing or exits at
    one of three terminal outcomes (supervisor stop, non-executable
    registry phase, or registry phase missing). The gate owns all FSM
    transitions, observability records, and manifest decisions tied to
    the phase-gate boundary. *)

type phase_gate_outcome =
  | Phase_gate_proceed of Keeper_state_machine.phase option
    (** Registry phase is executable (or unknown but recoverable); the
        caller may proceed to runtime routing. The carried [phase_opt]
        is the same value the gate observed in the registry, so the
        caller's runtime routing dispatches on the gate's view. *)
  | Phase_gate_cancelled of Keeper_meta_contract.keeper_meta
    (** Cooperative early-exit after a supervisor stop. The caller must retain
        this cancellation as a typed outcome; it is not completed work. *)
  | Phase_gate_skipped of Keeper_meta_contract.keeper_meta
    (** Cooperative early-exit in a non-executable registry phase. The caller
        must retain this skip as a typed outcome; it is not completed work. *)
  | Phase_gate_terminal_error of Agent_sdk.Error.sdk_error
    (** Hard early-exit: registry phase missing. [run_keeper_cycle]
        returns [Error err]. *)

val decide_and_record
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> generation:int
  -> keeper_turn_id:int
  -> append_phase_gate_decision:
       (Keeper_unified_turn_phase_plan.turn_plan
        -> Keeper_unified_turn_types.turn_state
        -> Keeper_unified_turn_types.turn_state)
  -> turn_state:Keeper_unified_turn_types.turn_state
  -> registry_base_path:string
  -> phase_gate_outcome * Keeper_unified_turn_types.turn_state
(** Run the phase gate logic, including all FSM transitions,
    observability records, and runtime-manifest decisions.

    On [Phase_gate_proceed], the gate has already transitioned the
    keeper FSM from [Phase_gating] to [Runtime_routing] and appended
    its decision via [append_phase_gate_decision]. The caller resumes
    with main-path runtime resolution.

    On either terminal outcome, the gate has recorded a
    pre-dispatch terminal observation, emitted the appropriate FSM
    transition, and the keeper turn is complete from the gate's
    perspective.

    @param config Workspace configuration passed through to observability.
    @param meta Current keeper metadata. Returned unchanged on
      [Phase_gate_cancelled] and [Phase_gate_skipped] outcomes.
    @param generation Current generation counter.
    @param keeper_turn_id Turn identifier assigned at function entry.
    @param append_phase_gate_decision Callback closing over the
      caller's [runtime_manifest_context]; takes the current
      [turn_state] and returns the updated state with the manifest
      decision appended. Called once per outcome.
    @param turn_state Immutable turn-state accumulator at phase-gate
      entry. The returned state reflects any manifest decision appended
      by the gate.
    @param registry_base_path Pre-resolved [config.base_path] reused
      from the caller's setup. *)
