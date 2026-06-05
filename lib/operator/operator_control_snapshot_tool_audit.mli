(** Tool audit helpers for operator control snapshot. *)

val lightweight_tool_audit_fallback_json :
  Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

val recent_tool_names_from_files : Workspace.config -> string -> string list

val keeper_tool_audit_fields :
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  string list
  * string list
  * int option
  * string option
  * string option
  * string option

val cached_tool_audit_json :
  lightweight:bool -> Workspace.config -> Keeper_meta_contract.keeper_meta -> Yojson.Safe.t
