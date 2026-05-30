(** JSON serializers for cascade catalog runtime diagnostics. *)

val candidate_probe_to_yojson :
  Cascade_catalog_runtime_cache.candidate_probe -> Yojson.Safe.t

val snapshot_to_yojson :
  Cascade_catalog_runtime_cache.snapshot -> Yojson.Safe.t

val rejection_to_yojson :
  Cascade_catalog_runtime_cache.rejection -> Yojson.Safe.t

val state_to_yojson :
  Cascade_catalog_runtime_cache.state -> Yojson.Safe.t
