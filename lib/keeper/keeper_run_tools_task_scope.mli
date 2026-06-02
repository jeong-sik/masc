(** Task-scoped tool helpers for keeper run tools. *)

val task_scope_tool_names : string list

val task_id_scope_of_tool_input :
  tool_name:string -> Yojson.Safe.t -> string option

val task_id_scope_of_claim_output :
  tool_name:string -> string -> string option

val task_id_scope_of_tool_call :
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_text:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  string option
