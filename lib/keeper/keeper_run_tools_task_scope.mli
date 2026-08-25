(** Task-scoped tool helpers for keeper run tools. *)

(* [task_scope_tool_names] and [task_id_scope_of_tool_input] are the inner
   steps of [task_id_scope_of_tool_call] below, which is the door callers use:
   it takes the call and answers the scope. Nothing outside needs the name list
   or the input-only form. *)

val task_id_scope_of_tool_call :
  tool_name:string ->
  input:Yojson.Safe.t ->
  meta:Keeper_meta_contract.keeper_meta ->
  string option
