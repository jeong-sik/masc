(** Keeper_approval_queue_failure_site — closed sum for [site] label on
    [metric_keeper_approval_queue_failures]. *)

type t =
  | Audit_store_create
  | Resolution_delivery
  | Resolution_signal
  | Audit_read_recent
  | Audit_list_recent_resolved

val to_label : t -> string
