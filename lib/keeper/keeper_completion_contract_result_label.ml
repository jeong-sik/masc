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

let all =
  [ Unknown, "unknown"
  ; Not_dispatched, "not_dispatched"
  ; Violated, "violated"
  ; Surface_mismatch, "surface_mismatch"
  ; No_capable_provider, "no_capable_provider"
  ; Claim_only_after_owned_task, "claim_only_after_owned_task"
  ; Needs_execution_progress, "needs_execution_progress"
  ; Passive_only, "passive_only"
  ; Satisfied_completion, "satisfied_completion"
  ; Satisfied_execution, "satisfied_execution"
  ]
;;

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

let of_string str =
  List.find_map
    (fun (label, encoded) -> if String.equal str encoded then Some label else None)
    all
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
