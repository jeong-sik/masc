type t =
  | Absent
  | Malformed_sha256
  | Unreadable

let failure_class = function
  | Absent -> Tool_result.Workflow_rejection
  | Malformed_sha256 -> Tool_result.Policy_rejection
  | Unreadable -> Tool_result.Runtime_failure
;;

let of_blob_store_error = function
  | Tool_blob_store.Invalid_sha256 _ -> Malformed_sha256
  | Tool_blob_store.Owned_read_failed _
  | Tool_blob_store.Too_large _
  | Tool_blob_store.Invalid_max_bytes _
  | Tool_blob_store.Integrity_mismatch _ -> Unreadable
;;

let failure_class_of_blob_store_error error =
  failure_class (of_blob_store_error error)
;;
