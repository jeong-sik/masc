(** Core tool-shard types and pure routing helpers. *)

(** A named collection of tools that can be granted or revoked. *)
type shard =
  { name : string
  ; tools : Masc_domain.tool_schema list
  ; read_only_tools : string list
  ; removable : bool
  ; description : string
  }

module StringMap : Map.S with type key = string

val select_named_schemas
  :  string list
  -> Masc_domain.tool_schema list
  -> Masc_domain.tool_schema list
(** Pick named schemas from a schema pool, preserving the requested order. *)

val default_shard_names : string list
(** Default shards granted to a fresh agent. *)

val tool_spec_read_only : string list
val tool_spec_destructive : string list

val tool_required_permission : string -> Masc_domain.permission option
(** Required permission for Tool_shard MASC tools. *)

val tool_effect_domain : string -> Tool_catalog.effect_domain option
(** Tool-catalog effect-domain classification for Tool_shard MASC tools. *)
