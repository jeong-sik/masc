(** Risk-contract projection of a [keeper_meta].  Currently always
    returns [None]; the prior contract derivation pipeline was
    removed in #6107 and no replacement has been wired in. *)
val of_keeper_meta :
  Keeper_types.keeper_meta -> Masc_mcp_cdal_runtime.Risk_contract.t option
