type t =
  | Unmapped_disposition
  | Emit_failed
  | Stale_broadcast

let to_label = function
  | Unmapped_disposition -> "unmapped_disposition"
  | Emit_failed -> "emit_failed"
  | Stale_broadcast -> "stale_broadcast"
;;
