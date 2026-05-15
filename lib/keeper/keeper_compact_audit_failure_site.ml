type t =
  | Retention_prune
  | Persist_start
  | Persist_complete
  | Handle_event

let to_label = function
  | Retention_prune -> "retention_prune"
  | Persist_start -> "persist_start"
  | Persist_complete -> "persist_complete"
  | Handle_event -> "handle_event"
;;
