(** Keeper_approval_queue_failure_site — closed sum for [site] label on
    [metric_keeper_approval_queue_failures]. *)

type t =
  | Upsert_rule_save
  | Audit_store_create
  | Audit_append
  | Resolution_delivery
  | Resolution_signal
  | Remember_rule

val to_label : t -> string
