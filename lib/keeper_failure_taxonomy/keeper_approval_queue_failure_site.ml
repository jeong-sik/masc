type t =
  | Upsert_rule_save
  | Audit_store_create
  | Audit_append
  | Resolution_delivery
  | Resolution_signal
  | Remember_rule

let to_label = function
  | Upsert_rule_save -> "upsert_rule_save"
  | Audit_store_create -> "audit_store_create"
  | Audit_append -> "audit_append"
  | Resolution_delivery -> "resolution_delivery"
  | Resolution_signal -> "resolution_signal"
  | Remember_rule -> "remember_rule"
;;
