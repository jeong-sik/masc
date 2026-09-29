(** Read-only portrait and equipment view for the current Keeper. *)

val handle
  :  keeper_name:string
  -> tool_name:string
  -> start_time:Tool_timing.started
  -> config:Workspace.config
  -> args:Yojson.Safe.t
  -> Tool_result.result
