(** Writes a turn's resolved attempt readings to the cost ledger, one
    [Cost_ledger.Resolved_attempt_delta] row per reading. A reading whose
    delta did not resolve is written as usage missing, with the status that
    says why. The caller writes them after the turn's meta commit, so a
    commit that fails leaves no row whose spend the next turn counts again.

    Every reading is written even when an earlier one fails. [Ok] means every
    row is in the ledger; [Error] carries the first failure, already logged
    and counted by {!Keeper_hooks_agent_core.emit_cost_event}. *)

val write
  :  masc_root:string
  -> agent_name:string
  -> task_id:string option
  -> trace_id:string
  -> keeper_turn_id:int
  -> Keeper_turn_spend.resolved list
  -> (unit, Keeper_hooks_agent_core.append_failure) result
