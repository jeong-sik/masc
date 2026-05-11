(** Write_meta_cycle_failure_site — closed sum for [site] label on
    [metric_keeper_write_meta_cycle_failures] (2 sites in
    keeper_unified_turn.ml). *)

type t =
  | Turn_failure
  | Keeper_cycle

val to_label : t -> string
