type t =
  | Audit_store_create
  | Resolution_delivery
  | Resolution_signal
  | Audit_read_recent
  | Audit_list_recent_resolved

let to_label = function
  | Audit_store_create -> "audit_store_create"
  | Resolution_delivery -> "resolution_delivery"
  | Resolution_signal -> "resolution_signal"
  | Audit_read_recent -> "audit_read_recent"
  | Audit_list_recent_resolved -> "audit_list_recent_resolved"
;;
