type t =
  | Migrate_main_history
  | Migrate_internal_history
  | Oas_parse
  | Oas_store
  | Oas_io
  | Oas_sdk
  | Load_legacy

let to_label = function
  | Migrate_main_history -> "migrate_main_history"
  | Migrate_internal_history -> "migrate_internal_history"
  | Oas_parse -> "oas_parse"
  | Oas_store -> "oas_store"
  | Oas_io -> "oas_io"
  | Oas_sdk -> "oas_sdk"
  | Load_legacy -> "load_legacy"
;;
