(** Visual axis cell for Keeper secondary row (RFC-0511 A1). *)

type tone =
  | Quiet
  | Attention
  | Failure

type t =
  { text : string
  ; tone : tone
  }
