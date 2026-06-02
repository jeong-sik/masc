(** Keeper-owned goal binding cleanup installed behind [Goal_janitor] hooks. *)

val install_hooks : unit -> unit
(** Install keeper-owned orphan-goal binding pruning hooks. *)
