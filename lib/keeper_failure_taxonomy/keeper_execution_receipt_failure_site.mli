(** Keeper_execution_receipt_failure_site — closed sum for [site] label on
    [metric_keeper_execution_receipt_failures]. *)

type t =
  | Unmapped_disposition
  | Emit_failed

val to_label : t -> string
