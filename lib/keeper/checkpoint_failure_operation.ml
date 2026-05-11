type t =
  | Migrate_main_history
  | Migrate_internal_history
  | Oas_parse
  | Oas_store
  | Oas_io
  | Oas_sdk
  | Load_legacy
  | Migration_save
  | Restore_legacy
  | Create_initial_save
  | Cleanup
  | Malformed_load

let to_label = function
  | Migrate_main_history -> "migrate_main_history"
  | Migrate_internal_history -> "migrate_internal_history"
  | Oas_parse -> "oas_parse"
  | Oas_store -> "oas_store"
  | Oas_io -> "oas_io"
  | Oas_sdk -> "oas_sdk"
  | Load_legacy -> "load_legacy"
  | Migration_save -> "migration_save"
  | Restore_legacy -> "restore_legacy"
  | Create_initial_save -> "create_initial_save"
  | Cleanup -> "cleanup"
  | Malformed_load -> "malformed_load"
;;
