(** Keeper_crash_persistence_failure_site — closed sum for [site] label on
    [masc_keeper_crash_persistence_failures_total]. *)

type t =
  | Crash_write

val to_label : t -> string
