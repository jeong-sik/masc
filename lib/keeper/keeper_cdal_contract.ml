(* Team session contract system removed (#6107). *)
let of_keeper_meta (_meta : Keeper_types.keeper_meta)
    : Agent_sdk.Risk_contract.t option =
  None
