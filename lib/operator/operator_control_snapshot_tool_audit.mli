(** Tool audit helpers for operator control snapshots. *)

type tool_audit_fields =
  string list
  * string list
  * string list
  * int option
  * string option
  * string option
  * string option

val lightweight_tool_audit_fallback_json :
  Keeper_types.keeper_meta -> Yojson.Safe.t

val cached_tool_audit_json :
  tool_audit_fields:
    (?include_allowed_tools:bool ->
     Coord.config ->
     Keeper_types.keeper_meta ->
     tool_audit_fields) ->
  lightweight:bool ->
  Coord.config ->
  Keeper_types.keeper_meta ->
  Yojson.Safe.t
