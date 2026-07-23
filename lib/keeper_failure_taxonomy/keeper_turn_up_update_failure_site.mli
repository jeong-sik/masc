(** Keeper_turn_up_update_failure_site — closed sum for [site] label on
    [metric_keeper_turn_up_update_failures] (4 sites in
    keeper_turn_up_update.ml). *)

type t =
  | Prompt_cap
  | Sandbox_validation
  | Runtime_assignment

val to_label : t -> string
