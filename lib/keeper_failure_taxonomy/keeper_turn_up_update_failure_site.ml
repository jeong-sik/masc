type t =
  | Prompt_cap
  | Sandbox_validation
  | Sandbox_preflight
  | Runtime_assignment

let to_label = function
  | Prompt_cap -> "prompt_cap"
  | Sandbox_validation -> "sandbox_validation"
  | Sandbox_preflight -> "sandbox_preflight"
  | Runtime_assignment -> "runtime_assignment"
;;
