(* Team session contract system removed (#6107). *)

(** Risk-contract projection of a [keeper_meta]. Always returns
    [None] since the team-session contract system was removed. *)
val of_keeper_meta :
  Keeper_types.keeper_meta -> Agent_sdk.Risk_contract.t option
