(** Outcome-kind polymorphic variant + bijection helpers for
    keeper execution receipts.

    Verbatim extract from the head of [Keeper_execution_receipt].
    The variant is polymorphic ([`Ok | `Skipped | `Error | `Cancelled]),
    so the parent re-export only needs a transparent type alias —
    polyvariants are structurally typed and constructors auto-share
    across module boundaries without re-declaration.

    Pure variant + total to/from-string + a small terminal-success
    predicate. No parent-local state. *)

type outcome_kind =
  [ `Ok
  | `Skipped
  | `Error
  | `Cancelled
  ]

let outcome_kind_to_string = function
  | `Ok -> "ok"
  | `Skipped -> "skipped"
  | `Error -> "error"
  | `Cancelled -> "cancelled"
;;

let outcome_kind_to_tla_receipt = function
  | `Ok -> "receipt_done"
  | `Skipped -> "receipt_skipped"
  | `Error -> "receipt_failed"
  | `Cancelled -> "receipt_cancelled"
;;

let outcome_kind_of_string = function
  | "ok" | "receipt_done" -> Some `Ok
  | "skipped" | "receipt_skipped" -> Some `Skipped
  | "error" | "receipt_failed" -> Some `Error
  | "cancelled" | "receipt_cancelled" -> Some `Cancelled
  | _ -> None
;;

let outcome_kind_is_terminal_success = function
  | `Ok | `Skipped -> true
  | `Error | `Cancelled -> false
;;
