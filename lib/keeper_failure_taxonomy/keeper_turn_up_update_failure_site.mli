(** Keeper_turn_up_update_failure_site — closed sum for the [site] label on
    [masc_keeper_turn_up_update_failures_total]. *)

type t =
  | Config_persistence
      (** Persisting the updated Keeper config failed (keeper_turn_up_update.ml). *)

val to_label : t -> string
