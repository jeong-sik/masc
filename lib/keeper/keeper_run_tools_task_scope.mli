(** Task-scoped tool helpers for keeper run tools. *)

val task_scope_tool_names : string list

val task_id_scope_of_tool_input :
  tool_name:string -> Yojson.Safe.t -> string option

type claim_output_scope_error =
  | Claim_output_json_parse_error of string
  | Claim_output_expected_object of { received : string }

val claim_output_scope_error_to_string : claim_output_scope_error -> string

val task_id_scope_of_claim_output_result :
  tool_name:string -> string -> (string option, claim_output_scope_error) result

val task_id_scope_of_claim_output :
  tool_name:string -> string -> string option

type task_id_scope_report = {
  task_id : string option;
  claim_output_error : claim_output_scope_error option;
}

val task_id_scope_of_tool_call_report :
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_text:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  task_id_scope_report

val task_id_scope_of_tool_call :
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_text:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  string option
