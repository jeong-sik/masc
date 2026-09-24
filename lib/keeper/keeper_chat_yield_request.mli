(** Read whether a newer, claimable person-chat operation is waiting for this
    Keeper's turn slot. The result is consumed only at a persisted tool
    boundary; it never interrupts an in-flight tool. *)

val request :
  base_path:string ->
  keeper_name:string ->
  (Keeper_agent_run.autonomous_yield_request option, string) result
