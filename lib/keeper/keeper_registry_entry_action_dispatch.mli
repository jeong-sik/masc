(** Entry-action observability (RFC-0002): a log side effect only — no
    registry state is read or written. *)

(** Emit the lifecycle log line for a [Publish_lifecycle] entry action. *)
val execute_observability :
  name:string ->
  phase:Keeper_state_machine.phase ->
  ts_unix:float ->
  Keeper_state_machine.entry_action -> unit
