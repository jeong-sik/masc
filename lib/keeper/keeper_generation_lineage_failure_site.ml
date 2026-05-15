type t =
  | Index_append
  | Manifest_save

let to_label = function
  | Index_append -> "index_append"
  | Manifest_save -> "manifest_save"
;;
