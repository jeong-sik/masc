(** Keeper tool runtime metadata and registered-schema injection. *)

(** Trim, drop empty entries, and dedupe a list preserving order. *)
val dedupe_tool_names : string list -> string list

(** Tool schemas declared by the [voice] shard, or [[]] when the
    shard is not registered. *)
val keeper_voice_tool_schemas : Masc_domain.tool_schema list

(** Descriptor-projected read-only tools. *)
val descriptor_read_only_tools : string list

(** All read-only keeper tools — shard read-only tools plus descriptor
    projections, sorted/deduped. *)
val keeper_read_only_tools : string list

val is_keeper_read_only_tool : string -> bool

(** Combined read-only check: keeper-local lookup plus descriptor/catalog
    read-only metadata. Idempotency never implies read-only behavior. *)
val is_effectively_read_only_tool : string -> bool

(** Compatibility alias for {!is_effectively_read_only_tool}. *)
val is_strictly_read_only_tool : string -> bool

(** Negation of [is_effectively_read_only_tool]. *)
val has_mutating_side_effect : string -> bool

(** Input-aware read-only check for tools that mix read-only and mutating
    subcommands within one tool name. *)
val is_read_only_with_input :
  tool_name:string -> input:Yojson.Safe.t -> bool

(** Input-aware strict read-only check. This uses descriptor
    [readonly_of_input] when present and otherwise falls back to
    [is_strictly_read_only_tool]. *)
val is_strictly_read_only_with_input :
  tool_name:string -> input:Yojson.Safe.t -> bool

(** Replace injected MASC tool schemas.
    Startup calls this through [inject_masc_schemas]; runtime readers should
    use [masc_schemas_snapshot] rather than holding mutable state. *)
val set_masc_schemas : Masc_domain.tool_schema list -> unit

(** Immutable snapshot of injected MASC tool schemas. *)
val masc_schemas_snapshot : unit -> Masc_domain.tool_schema list

(** Names extracted from [masc_schemas_snapshot ()] in declaration order. *)
val injected_masc_tool_names : unit -> string list

(** SSOT schema for [keeper_tool_search]. Defined here because this
    module is the canonical owner of keeper-internal tool metadata. *)
val keeper_tool_search_schema : Masc_domain.tool_schema
