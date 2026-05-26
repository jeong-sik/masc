(** Completion contract — required-tool-use gating for keeper turns. *)

type completion_contract =
  | Allow_text_or_tool
  | Require_tool_use

val merge_completion_contract
  :  previous:completion_contract
  -> current:completion_contract
  -> completion_contract

val completion_contract_of_tool_choice
  :  Agent_sdk.Types.tool_choice option
  -> completion_contract

val run_completion_contract
  :  turn_contract:completion_contract
  -> required_tool_use_seen:bool
  -> completion_contract

val validate_completion_contract_presence
  :  contract:completion_contract
  -> tool_present:bool
  -> (unit, string) result

val validate_completion_contract
  :  contract:completion_contract
  -> tool_names:string list
  -> unit
  -> (unit, string) result
