type t =
  | Oas_cleanup
  | Oas_save
  | Oas_delete
  | Oas_archive_fallback
  | Oas_archive_primary
  | Oas_watermark_load

let to_label = function
  | Oas_cleanup -> "oas_cleanup"
  | Oas_save -> "oas_save"
  | Oas_delete -> "oas_delete"
  | Oas_archive_fallback -> "oas_archive_fallback"
  | Oas_archive_primary -> "oas_archive_primary"
  | Oas_watermark_load -> "oas_watermark_load"
;;
