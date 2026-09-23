(** Outcome-kind polymorphic variant and projection helpers for keeper execution
    receipts. *)

type outcome_kind =
  [ `Ok
  | `Skipped
  | `Error
  | `Cancelled
  ]

val outcome_kind_to_string : outcome_kind -> string
val outcome_kind_to_tla_receipt : outcome_kind -> string

(** Inverse of {!outcome_kind_to_tla_receipt}; [None] for any other string. *)
val outcome_kind_of_tla_receipt : string -> outcome_kind option

val outcome_kind_is_terminal_success : outcome_kind -> bool
