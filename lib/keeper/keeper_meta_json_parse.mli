(** Exact current-schema Keeper meta JSON parser. *)

val meta_of_json :
  Yojson.Safe.t -> (Keeper_meta_contract.keeper_meta, string) result
(** Decode only the exact top-level shape emitted by
    [Keeper_meta_json.meta_to_json]. Missing, wrong-typed, retired, duplicate,
    unknown, or malformed fields are explicit reset-required errors. Nullable
    domain fields still accept their current [`Null] representation. *)
