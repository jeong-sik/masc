(** Keeper trust projection for the dashboard. *)

val keeper_trust_json :
  ?include_receipt:bool ->
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  Yojson.Safe.t
