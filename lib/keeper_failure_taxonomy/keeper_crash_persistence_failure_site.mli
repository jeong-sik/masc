(** Keeper_crash_persistence_failure_site — closed sum for [site] label on
    [metric_keeper_crash_persistence_failures]. *)

type t =
  | Crash_write

val to_label : t -> string
