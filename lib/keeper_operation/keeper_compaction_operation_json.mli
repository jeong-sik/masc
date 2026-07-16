(** Canonical JSON projection of typed compaction operation facts. *)

val to_json : Keeper_compaction_operation.event -> Yojson.Safe.t
