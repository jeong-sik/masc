type t =
  | Prompt_cap
  | Sandbox_validation
  | Runtime_assignment

let to_label = function
  | Prompt_cap -> "prompt_cap"
  | Sandbox_validation -> "sandbox_validation"
  | Runtime_assignment -> "runtime_assignment"
;;
