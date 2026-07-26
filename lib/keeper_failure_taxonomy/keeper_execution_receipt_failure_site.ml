type t =
  | Unmapped_disposition
  | Emit_failed

let to_label = function
  | Unmapped_disposition -> "unmapped_disposition"
  | Emit_failed -> "emit_failed"
;;
