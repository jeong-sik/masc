(** Single identity-repair path backed by lifecycle nonce witnesses. *)

val replace_or_recover_exact :
  Keeper_lifecycle_admission.Durable_transaction.permit ->
  config:Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  expected_agent_name:string ->
  (Keeper_meta_contract.keeper_meta, string) result
