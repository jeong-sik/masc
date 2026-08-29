type t =
  | Agent_core_parse
  | Agent_core_store
  | Agent_core_io
  | Agent_core_failure
  | Agent_core_sanitize_save
  | Create_initial_save

let to_label = function
  | Agent_core_parse -> "agent_core_parse"
  | Agent_core_store -> "agent_core_store"
  | Agent_core_io -> "agent_core_io"
  | Agent_core_failure -> "agent_core"
  | Agent_core_sanitize_save -> "agent_core_sanitize_save"
  | Create_initial_save -> "create_initial_save"
;;
