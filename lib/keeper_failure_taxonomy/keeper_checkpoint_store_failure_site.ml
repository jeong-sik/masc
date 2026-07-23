type t =
  | Oas_cleanup
  | Oas_save
  | Oas_delete
  | Oas_archive

let to_label = function
  | Oas_cleanup -> "oas_cleanup"
  | Oas_save -> "oas_save"
  | Oas_delete -> "oas_delete"
  | Oas_archive -> "oas_archive"
;;
