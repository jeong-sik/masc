type t =
  | Save
  | Oas_cleanup
  | Oas_save
  | Oas_delete
  | Oas_archive_fallback
  | Oas_archive_primary

let to_label = function
  | Save -> "save"
  | Oas_cleanup -> "oas_cleanup"
  | Oas_save -> "oas_save"
  | Oas_delete -> "oas_delete"
  | Oas_archive_fallback -> "oas_archive_fallback"
  | Oas_archive_primary -> "oas_archive_primary"
;;
