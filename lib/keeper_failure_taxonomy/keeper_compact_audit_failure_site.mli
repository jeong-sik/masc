(** Closed label for failures in the remaining explicit MASC compaction-audit
    retention path. *)

type t =
  | Retention_prune

val to_label : t -> string
