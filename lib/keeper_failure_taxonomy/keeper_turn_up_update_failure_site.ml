type t =
  | Prompt_cap
  | Sandbox_validation
  | Runtime_assignment
  | Config_persistence

let to_label = function
  | Prompt_cap -> "prompt_cap"
  | Sandbox_validation -> "sandbox_validation"
  | Runtime_assignment -> "runtime_assignment"
  | Config_persistence -> "config_persistence"
;;
