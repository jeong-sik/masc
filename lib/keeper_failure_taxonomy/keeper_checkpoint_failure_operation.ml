type t =
  | Oas_parse
  | Oas_store
  | Oas_io
  | Oas_sdk
  | Oas_sanitize_save
  | Create_initial_save
  | Compaction_save

let to_label = function
  | Oas_parse -> "oas_parse"
  | Oas_store -> "oas_store"
  | Oas_io -> "oas_io"
  | Oas_sdk -> "oas_sdk"
  | Oas_sanitize_save -> "oas_sanitize_save"
  | Create_initial_save -> "create_initial_save"
  | Compaction_save -> "compaction_save"
;;
