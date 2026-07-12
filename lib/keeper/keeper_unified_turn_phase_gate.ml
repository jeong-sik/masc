(* Keeper_unified_turn_phase_gate — RFC-0136 PR-1.

   Extracted from keeper_unified_turn.ml (L129-L255) during the
   run_keeper_cycle stage decomposition. The gate owns the three
   pre-dispatch early-exit paths plus the FSM transition into
   Runtime_routing on the proceed path. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

type phase_gate_outcome =
  | Phase_gate_proceed of Keeper_state_machine.phase option
  | Phase_gate_cancelled of keeper_meta
  | Phase_gate_skipped of keeper_meta
  | Phase_gate_terminal_error of Agent_sdk.Error.sdk_error

let decide_and_record
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(generation : int)
      ~(keeper_turn_id : int)
      ~(append_phase_gate_decision :
         Keeper_unified_turn_phase_plan.turn_plan
         -> Keeper_unified_turn_types.turn_state
         -> Keeper_unified_turn_types.turn_state)
      ~(turn_state : Keeper_unified_turn_types.turn_state)
      ~(registry_base_path : string)
  =
  let supervisor_stop_at_entry =
    match Keeper_registry.get ~base_path:registry_base_path meta.name with
    | Some entry -> Atomic.get entry.fiber_stop
    | None -> false
  in
  if supervisor_stop_at_entry
  then (
    let turn_plan =
      Keeper_unified_turn_phase_plan.decide_turn_plan_at_phase_gate
        ~keeper_turn_id
        ~supervisor_stop_at_entry:true None
    in
    let turn_state = append_phase_gate_decision turn_plan turn_state in
    Log.Keeper.info
      ~keeper_name:meta.name
      ~turn_id:keeper_turn_id
      "%s: supervisor stop signal observed at turn entry — honoring (phase_gating)"
      meta.name;
    (* FSM: SupervisorRequestsStop — stop signal raised while in active state *)
    Keeper_turn_fsm.emit_transition
      ~keeper_name:meta.name
      ~turn_id:keeper_turn_id
      ~prev:Keeper_turn_fsm.Phase_gating
      Keeper_turn_fsm.Phase_gating;
    Keeper_turn_helpers.record_pre_dispatch_terminal_observation
      ~config
      ~meta
      ~generation
      ~runtime_id:
        (           (runtime_id_of_meta meta))
      ~outcome:`Cancelled
      ~terminal_reason_code:"supervisor_stop"
      ~activity_kind:"keeper.turn_cancelled"
      ~trajectory_outcome:(Trajectory.Gated "supervisor_stop")
      ~keeper_turn_id
      ();
    (* FSM: HonorStopSignal — cooperative cancel at phase_gating *)
    Keeper_turn_fsm.emit_transition
      ~keeper_name:meta.name
      ~turn_id:keeper_turn_id
      ~prev:Keeper_turn_fsm.Phase_gating
      (Keeper_turn_fsm.Cancelled Keeper_turn_fsm.Cancelled_supervisor_stop);
    Phase_gate_cancelled meta, turn_state)
  else (
    match
      Keeper_registry.get_phase ~base_path:registry_base_path meta.name
    with
    | Some phase when not (Keeper_state_machine.can_execute_turn phase) ->
      let turn_plan =
        Keeper_unified_turn_phase_plan.decide_turn_plan_at_phase_gate
          ~keeper_turn_id
          ~supervisor_stop_at_entry:false (Some phase)
      in
      let phase_string = Keeper_state_machine.phase_to_string phase in
      let turn_state = append_phase_gate_decision turn_plan turn_state in
      Log.Keeper.info
        ~keeper_name:meta.name
        ~turn_id:keeper_turn_id
        "%s: keeper cycle skipped in non-executable phase=%s"
        meta.name
        phase_string;
      let terminal_reason_code =
        Printf.sprintf "non_executable_phase:%s" phase_string
      in
      Keeper_turn_helpers.record_pre_dispatch_terminal_observation
        ~config
        ~meta
        ~generation
        ~runtime_id:
          (             (runtime_id_of_meta meta))
        ~outcome:`Skipped
        ~terminal_reason_code
        ~activity_kind:"keeper.turn_skipped"
        ~trajectory_outcome:(Trajectory.Gated terminal_reason_code)
        ~keeper_turn_id
        ();
      Keeper_turn_fsm.emit_transition
        ~keeper_name:meta.name
        ~turn_id:keeper_turn_id
        ~prev:Keeper_turn_fsm.Phase_gating
        Keeper_turn_fsm.Done;
      Phase_gate_skipped meta, turn_state
    | None ->
      let turn_plan =
        Keeper_unified_turn_phase_plan.decide_turn_plan_at_phase_gate
          ~keeper_turn_id
          ~supervisor_stop_at_entry:false None
      in
      let terminal_reason_code = "registry_phase_missing" in
      let error_message =
        Printf.sprintf
          "%s: keeper registry phase lookup returned None before dispatch"
          meta.name
      in
      let turn_state = append_phase_gate_decision turn_plan turn_state in
      Log.Keeper.error
        ~keeper_name:meta.name
        ~turn_id:keeper_turn_id
        "%s"
        error_message;
      Keeper_turn_helpers.record_pre_dispatch_terminal_observation
        ~config
        ~meta
        ~generation
        ~runtime_id:
          (             (runtime_id_of_meta meta))
        ~outcome:`Error
        ~terminal_reason_code
        ~activity_kind:"keeper.turn_blocked"
        ~trajectory_outcome:(Trajectory.Failed terminal_reason_code)
        ~error_kind:
          (Keeper_execution_receipt.error_kind_of_string terminal_reason_code)
        ~error_message
        ~keeper_turn_id
        ();
      Keeper_turn_fsm.emit_transition
        ~keeper_name:meta.name
        ~turn_id:keeper_turn_id
        ~prev:Keeper_turn_fsm.Phase_gating
        (Keeper_turn_fsm.Failed
           (Keeper_turn_fsm.Failure_runtime_error terminal_reason_code));
      Phase_gate_terminal_error (Agent_sdk.Error.Internal error_message), turn_state
    | phase_opt ->
      let turn_plan =
        Keeper_unified_turn_phase_plan.decide_turn_plan_at_phase_gate
          ~keeper_turn_id
          ~supervisor_stop_at_entry:false phase_opt
      in
      let turn_state = append_phase_gate_decision turn_plan turn_state in
      Keeper_turn_fsm.emit_transition
        ~keeper_name:meta.name
        ~turn_id:keeper_turn_id
        ~prev:Keeper_turn_fsm.Phase_gating
        Keeper_turn_fsm.Runtime_routing;
      Phase_gate_proceed phase_opt, turn_state)
