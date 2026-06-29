type t =
  | Prompt_cap
  | No_progress_resume_clear
  | Sandbox_validation
  | Sandbox_preflight
  | Runtime_assignment

let to_label = function
  | Prompt_cap -> "prompt_cap"
  | No_progress_resume_clear -> "no_progress_resume_clear"
  | Sandbox_validation -> "sandbox_validation"
  | Sandbox_preflight -> "sandbox_preflight"
  | Runtime_assignment -> "runtime_assignment"
;;
