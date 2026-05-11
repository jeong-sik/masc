(** Crash_persistence_failure_site — closed sum for [site] label on
    [metric_keeper_crash_persistence_failures] (2 sites). *)

type t =
  | Crash_write
  | Sp_write

val to_label : t -> string
