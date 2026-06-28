type t =
  | Unknown
  | Not_dispatched
  | Violated
  | Surface_mismatch
  | No_capable_provider
  | Claim_only_after_owned_task
  | Needs_execution_progress
  | Passive_only
  | Satisfied_completion
  | Satisfied_execution

let to_string = function
  | Unknown -> "unknown"
  | Not_dispatched -> "not_dispatched"
  | Violated -> "violated"
  | Surface_mismatch -> "surface_mismatch"
  | No_capable_provider -> "no_capable_provider"
  | Claim_only_after_owned_task -> "claim_only_after_owned_task"
  | Needs_execution_progress -> "needs_execution_progress"
  | Passive_only -> "passive_only"
  | Satisfied_completion -> "satisfied_completion"
  | Satisfied_execution -> "satisfied_execution"
;;

let of_string = function
  | "unknown" -> Some Unknown
  | "not_dispatched" -> Some Not_dispatched
  | "violated" -> Some Violated
  | "surface_mismatch" -> Some Surface_mismatch
  | "no_capable_provider" -> Some No_capable_provider
  | "claim_only_after_owned_task" -> Some Claim_only_after_owned_task
  | "needs_execution_progress" -> Some Needs_execution_progress
  | "passive_only" -> Some Passive_only
  | "satisfied_completion" -> Some Satisfied_completion
  | "satisfied_execution" -> Some Satisfied_execution
  | _ -> None
;;

let requires_attention = function
  | Violated
  | Surface_mismatch
  | No_capable_provider
  | Claim_only_after_owned_task
  | Needs_execution_progress
  | Passive_only ->
    true
  | Unknown
  | Not_dispatched
  | Satisfied_completion
  | Satisfied_execution ->
    false
;;
