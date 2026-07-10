type t =
  | Upsert_rule_save
  | Matching_rule_save
  | Audit_store_create
  | Resolution_delivery
  | Resolution_signal
  | Resolution_callback
  | Remember_rule
  | Approval_expired
  | Expire_callback
  | Audit_read_recent
  | Audit_list_recent_resolved

let to_label = function
  | Upsert_rule_save -> "upsert_rule_save"
  | Matching_rule_save -> "matching_rule_save"
  | Audit_store_create -> "audit_store_create"
  | Resolution_delivery -> "resolution_delivery"
  | Resolution_signal -> "resolution_signal"
  | Resolution_callback -> "resolution_callback"
  | Remember_rule -> "remember_rule"
  | Approval_expired -> "approval_expired"
  | Expire_callback -> "expire_callback"
  | Audit_read_recent -> "audit_read_recent"
  | Audit_list_recent_resolved -> "audit_list_recent_resolved"
;;
