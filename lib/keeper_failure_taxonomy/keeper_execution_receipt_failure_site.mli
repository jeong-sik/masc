(** Keeper_execution_receipt_failure_site — closed sum for [site] label on
    [masc_keeper_execution_receipt_failures_total]. *)

type t =
  | Unmapped_disposition
  | Emit_failed

val to_label : t -> string
