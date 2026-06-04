(** Core shard types and routing helpers for tool shard schemas. *)

type shard =
  { name : string
  ; tools : Masc_domain.tool_schema list
  ; read_only_tools : string list
  ; removable : bool
  ; description : string
  }

module StringMap : Map.S with type key = string

val select_named_schemas :
  string list -> Masc_domain.tool_schema list -> Masc_domain.tool_schema list

val default_shard_names : string list
val tool_spec_read_only : string list
val tool_spec_destructive : string list
val tool_effect_domain : string -> Tool_catalog.effect_domain option
