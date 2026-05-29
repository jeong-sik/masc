(** Fleet readiness JSON builders for the dashboard composite endpoint. *)

val keeper_activation_readiness_json : Keeper_meta_contract.keeper_meta -> Yojson.Safe.t
