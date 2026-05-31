type t = latest:Keeper_meta_contract.keeper_meta -> caller:Keeper_meta_contract.keeper_meta -> Keeper_meta_contract.keeper_meta

let caller_wins ~(latest : Keeper_meta_contract.keeper_meta) ~(caller : Keeper_meta_contract.keeper_meta) =
  { caller with meta_version = latest.meta_version }

let heartbeat_fields_from_disk = caller_wins
