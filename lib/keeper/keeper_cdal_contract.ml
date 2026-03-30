module Oas = Agent_sdk

let of_keeper_meta (meta : Keeper_types.keeper_meta)
    : Oas.Risk_contract.t option =
  Some (Cdal_contract_bridge.of_keeper_meta meta)
