type t =
  | Tool_code_write_load_failed
  | Policy_config_not_loaded

let to_label = function
  | Tool_code_write_load_failed -> "tool_code_write_load_failed"
  | Policy_config_not_loaded -> "policy_config_not_loaded"
;;
