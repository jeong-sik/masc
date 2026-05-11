(** Compact_audit_failure_site — closed sum for [site] label on
    [metric_keeper_compact_audit_failures] (4 sites). *)

type t =
  | Retention_prune
  | Persist_start
  | Persist_complete
  | Handle_event

val to_label : t -> string
