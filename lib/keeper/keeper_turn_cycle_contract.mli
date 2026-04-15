(** KeeperTurnCycle contract helpers.

    Closed OCaml variants for the named action and invariant sets exposed by
    [specs/keeper-state-machine/KeeperTurnCycle.tla]. State sets reuse the
    runtime variants in {!Keeper_registry}/{!Keeper_composite_observer}; this
    module only closes the TLA-specific action and invariant labels so tests can
    assert a 1:1 mapping without string literals. *)

type tla_action =
  | Action_start_turn
  | Action_bind_measurement
  | Action_guard_ok
  | Action_select_tool_policy
  | Action_gate_rejected
  | Action_cascade_trying
  | Action_cascade_done
  | Action_cascade_exhausted
  | Action_enter_compacting
  | Action_retry_after_compaction
  | Action_finish_turn

type invariant_key =
  | Inv_no_live_turn_clears_state
  | Inv_idle_requires_not_live
  | Inv_gate_rejected_requires_finalizing
  | Inv_selecting_requires_tool_policy
  | Inv_executing_requires_trying
  | Inv_compacting_requires_trying
  | Inv_terminal_cascade_requires_finalizing

val all_tla_actions : tla_action list
val all_invariant_keys : invariant_key list

val tla_action_to_string : tla_action -> string
val tla_action_of_string : string -> tla_action option

val invariant_key_to_string : invariant_key -> string
val invariant_key_of_string : string -> invariant_key option
