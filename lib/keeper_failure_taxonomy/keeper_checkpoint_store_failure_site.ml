type t =
  | Agent_core_cleanup
  | Agent_core_save
  | Agent_core_delete
  | Agent_core_archive

let to_label = function
  | Agent_core_cleanup -> "agent_core_cleanup"
  | Agent_core_save -> "agent_core_save"
  | Agent_core_delete -> "agent_core_delete"
  | Agent_core_archive -> "agent_core_archive"
;;
