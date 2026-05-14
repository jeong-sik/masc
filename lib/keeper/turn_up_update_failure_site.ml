type t =
  | Prompt_cap
  | Sandbox_validation
  | Sandbox_preflight

let to_label = function
  | Prompt_cap -> "prompt_cap"
  | Sandbox_validation -> "sandbox_validation"
  | Sandbox_preflight -> "sandbox_preflight"
;;
