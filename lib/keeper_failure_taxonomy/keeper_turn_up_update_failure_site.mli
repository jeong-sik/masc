(** Keeper_turn_up_update_failure_site — closed sum for [site] label on
    [metric_keeper_turn_up_update_failures] (5 sites in
    keeper_turn_up_update.ml). *)

type t =
  | Prompt_cap
  | No_progress_resume_clear
  | Sandbox_validation
  | Sandbox_preflight
  | Runtime_assignment

val to_label : t -> string
