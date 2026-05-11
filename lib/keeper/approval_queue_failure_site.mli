(** Approval_queue_failure_site — closed sum for [site] label on
    [metric_keeper_approval_queue_failures] (7 sites). *)

type t =
  | Upsert_rule_save
  | Matching_rule_save
  | Audit_store_create
  | Resolution_callback
  | Remember_rule
  | Approval_expired
  | Expire_callback

val to_label : t -> string
