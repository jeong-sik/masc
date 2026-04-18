(** Keeper memory tool handlers — search, context status. *)

val keeper_memory_search_json :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ctx_work:Keeper_types.working_context ->
  args:Yojson.Safe.t ->
  string

val keeper_context_status_json :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ctx_work:Keeper_types.working_context ->
  string
