(** KeeperDecisionPipeline contract helpers.

    Closed OCaml variants for the action/invariant sets exposed by
    [specs/keeper-state-machine/KeeperDecisionPipeline.tla]. The runtime state
    set itself is the shared [Keeper_registry.decision_stage] ADT; this module
    covers only the TLA-specific labels so regressions cannot hide behind raw
    strings. *)

type tla_action =
  | Action_start_turn
  | Action_bind_measurement
  | Action_guard_ok
  | Action_select_tool_policy
  | Action_cascade_trying
  | Action_gate_rejected
  | Action_retry_after_compaction
  | Action_finish_turn

type invariant_key =
  | Inv_no_live_turn_clears_decision
  | Inv_idle_requires_undecided
  | Inv_guard_ok_requires_measurement
  | Inv_gate_rejected_requires_finalizing
  | Inv_non_idle_cascade_requires_decision_boundary
  | Inv_selecting_requires_prompting

val all_tla_actions : tla_action list
val all_invariant_keys : invariant_key list

val tla_action_to_string : tla_action -> string
val tla_action_of_string : string -> tla_action option

val invariant_key_to_string : invariant_key -> string
val invariant_key_of_string : string -> invariant_key option
