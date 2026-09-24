(** Keeper trust projection for the dashboard. *)

val keeper_trust_json :
  ?include_receipt:bool ->
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  Yojson.Safe.t

(** Trust fields for the row shown when a Keeper's dashboard row could not be
    built. [site] names where it failed; [attention_reason] is the error when
    one was caught, else [site]. No receipt is read, so [operator_disposition]
    and [operator_disposition_reason] are [null]. *)
val degraded_keeper_trust_json :
  site:string -> attention_reason:string -> Yojson.Safe.t
