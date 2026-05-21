(** Tool audit helpers for operator control snapshots. *)

val lightweight_tool_audit_fallback_json :
  Keeper_types.keeper_meta -> Yojson.Safe.t

val cached_tool_audit_json :
  lightweight:bool ->
  Coord.config ->
  Keeper_types.keeper_meta ->
  Yojson.Safe.t
