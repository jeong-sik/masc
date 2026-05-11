type t =
  | Upsert_rule_save
  | Matching_rule_save
  | Audit_store_create
  | Resolution_callback
  | Remember_rule
  | Approval_expired
  | Expire_callback

let to_label = function
  | Upsert_rule_save -> "upsert_rule_save"
  | Matching_rule_save -> "matching_rule_save"
  | Audit_store_create -> "audit_store_create"
  | Resolution_callback -> "resolution_callback"
  | Remember_rule -> "remember_rule"
  | Approval_expired -> "approval_expired"
  | Expire_callback -> "expire_callback"
;;
