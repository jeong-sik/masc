(** Tool audit helpers for operator control snapshots. *)

val lightweight_tool_audit_fallback_json :
  Keeper_types.keeper_meta -> Yojson.Safe.t

val recent_tool_names_from_files : Coord.config -> string -> string list

val keeper_tool_audit_fields :
  ?include_allowed_tools:bool ->
  Coord.config ->
  Keeper_types.keeper_meta ->
  string list
  * string list
  * string list
  * int option
  * string option
  * string option
  * string option

val cached_tool_audit_json :
  lightweight:bool ->
  Coord.config ->
  Keeper_types.keeper_meta ->
  Yojson.Safe.t
