(** Turn_up_update_failure_site — closed sum for [site] label on
    [metric_keeper_turn_up_update_failures] (3 sites in
    keeper_turn_up_update.ml). *)

type t =
  | Prompt_cap
  | Sandbox_validation
  | Sandbox_preflight

val to_label : t -> string
