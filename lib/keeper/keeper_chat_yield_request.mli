(** Read whether a newer, claimable person-chat operation is waiting for this
    Keeper's turn slot. An autonomous turn can use this before its first
    provider event. A claimed direct turn uses it after a settled tool result,
    then retains a continuation before handing over the turn slot. *)

val request :
  base_path:string ->
  keeper_name:string ->
  (Keeper_agent_run.autonomous_yield_request option, string) result
