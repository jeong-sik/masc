(** Execution_receipt_failure_site — closed sum for [site] label on
    [metric_keeper_execution_receipt_failures] (3 sites). *)

type t =
  | Unmapped_disposition
  | Emit_failed
  | Stale_broadcast

val to_label : t -> string
