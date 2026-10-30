(** Keeper trust projection for the dashboard. *)

val keeper_trust_json :
  ?include_receipt:bool ->
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  Yojson.Safe.t

(** Trust fields for the row shown when the dashboard worker raised while
    building a Keeper's row. The disposition reason is
    [keeper_dashboard_worker_exception] and the attention reason is [error].
    No receipt is read, so [operator_disposition] and
    [operator_disposition_reason] are [null]. *)
val degraded_keeper_trust_json : error:string -> Yojson.Safe.t
