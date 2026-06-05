(** Claim kind + status variants for keeper accountability records. *)

type claim_kind =
  | Task_commitment
  | Completion_claim

type claim_status =
  | Pending
  | Supported
  | Unsupported
  | Expired
  | Partial

val claim_kind_to_string : claim_kind -> string
val claim_kind_of_string : string -> claim_kind option
val claim_status_to_string : claim_status -> string
val claim_status_of_string : string -> claim_status option
