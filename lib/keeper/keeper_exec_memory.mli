(** Keeper memory tool handlers — search, context status. *)

(** Issue #8484: Variant SSOT for memory search scope.  Mirror in
    [Tool_shard.memory_search_source_enum_strings] (cycle avoidance,
    sync regression test catches drift). *)
type memory_search_source =
  | Memory
  | History
  | All

val memory_search_source_to_string : memory_search_source -> string
val memory_search_source_of_string_opt : string -> memory_search_source option
val all_memory_search_sources : memory_search_source list
val valid_memory_search_source_strings : string list

val keeper_memory_search_json
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> ctx_work:Keeper_types.working_context
  -> args:Yojson.Safe.t
  -> string

val keeper_context_status_json
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> ctx_work:Keeper_types.working_context
  -> string
