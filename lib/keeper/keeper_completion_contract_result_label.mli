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

val to_string : t -> string
val of_string : string -> t option
val requires_attention : t -> bool
