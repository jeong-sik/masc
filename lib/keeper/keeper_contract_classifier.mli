(** Typed classifier for keeper turn completion contract.

    Step 6a of the bloodflow restoration plan introduces only the
    type vocabulary; the call-site rewrite that replaces the
    [String_util.contains_substring_ci haystack ...] heuristic in
    [keeper_agent_run.ml:2285-2298] is left to a follow-up stack
    so the type surface lands additively first. *)

type actionable_signal =
  | Has_unclaimed_tasks
  | Has_board_activity
  | Has_discovered_work
  | No_actionable_signal
      (** Caller observed neither tasks, board activity, nor
          discovered-work markers in the structured world snapshot. *)

type contract_status =
  | Tool_surface_mismatch of { missing : string list }
  | Missing_required_tool_use
  | Claim_only_after_owned_task
  | Needs_execution_progress
  | Passive_only
  | Satisfied_completion
  | Satisfied_execution

val actionable_signal_label : actionable_signal -> string
val contract_status_label : contract_status -> string
val pp_contract_status : Format.formatter -> contract_status -> unit
