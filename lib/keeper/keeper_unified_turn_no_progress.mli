(** Operator-resume cleanup for the unified keeper turn.

    RFC-0303 Phase 3: the no-progress loop detector is retired; loop
    detection/marking helpers were removed. Only operator-resume cleanup
    remains. *)

val failure_reason_code : string

val clear_for_operator_resume
  :  base_path:string
  -> Keeper_meta_contract.keeper_meta
  -> (Keeper_meta_contract.keeper_meta, string) result
