(** Risk-contract projection of a [keeper_meta].

    Keeper turns use a capture-only contract: it asks CDAL/OAS to record
    proof and effect evidence for the turn without adding an extra review
    gate or tightening the keeper's already-configured tool policy. *)
val of_keeper_meta :
  Keeper_types.keeper_meta -> Masc_mcp_cdal_runtime.Risk_contract.t option
