type t =
  | Persist_ok
  | Persist_failed
  | Retrieve_hit
  | Retrieve_miss
  | Remove_ok
  | Remove_failed
  | Batch_persist_ok
  | Batch_persist_failed
  | Query_ok
  | Query_failed

let to_label = function
  | Persist_ok -> "persist_ok"
  | Persist_failed -> "persist_failed"
  | Retrieve_hit -> "retrieve_hit"
  | Retrieve_miss -> "retrieve_miss"
  | Remove_ok -> "remove_ok"
  | Remove_failed -> "remove_failed"
  | Batch_persist_ok -> "batch_persist_ok"
  | Batch_persist_failed -> "batch_persist_failed"
  | Query_ok -> "query_ok"
  | Query_failed -> "query_failed"
;;
