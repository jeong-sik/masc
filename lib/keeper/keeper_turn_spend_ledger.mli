(** Writes a turn's resolved attempt readings to the cost ledger, one
    [Cost_ledger.Resolved_attempt_delta] row per reading. A reading whose
    delta did not resolve is written as usage missing, with the status that
    says why. The caller writes them after the turn's meta commit, so a
    commit that fails leaves no row whose spend the next turn counts again. *)

val write
  :  masc_root:string
  -> agent_name:string
  -> task_id:string option
  -> trace_id:string
  -> keeper_turn_id:int
  -> Keeper_turn_spend.resolved list
  -> unit
