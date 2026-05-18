(** Idle-loop decision helpers for [Keeper_hooks_oas]. *)

val suggest_alternatives
  :  allowed_tools:string list
  -> repeated_tools:string list
  -> max_suggestions:int
  -> string list

val on_idle_decision_with_threshold
  :  skip_at:int
  -> consecutive_idle_turns:int
  -> allowed_tools:string list
  -> tool_names:string list
  -> Agent_sdk.Hooks.hook_decision

val on_idle_decision
  :  consecutive_idle_turns:int
  -> allowed_tools:string list
  -> tool_names:string list
  -> Agent_sdk.Hooks.hook_decision

val keeper_idle_decision
  :  meta_ref:Keeper_types.keeper_meta ref
  -> consecutive_idle_turns:int
  -> tool_names:string list
  -> Agent_sdk.Hooks.hook_decision

val recent_tool_streak_count
  :  ?within_sec:float
  -> tool_name:string
  -> Yojson.Safe.t list
  -> int
