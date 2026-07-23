(** Keeper tool runtime metadata and registered-schema injection. *)

(** Trim, drop empty entries, and dedupe a list preserving order. *)
val dedupe_tool_names : string list -> string list

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
