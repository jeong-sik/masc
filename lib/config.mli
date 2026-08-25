(** Tool schema registry and visibility helpers. *)

val raw_all_tool_schemas : Masc_domain.tool_schema list
(** All tool schemas before capability filtering. *)

val validate_schemas : Masc_domain.tool_schema list -> unit
(** Validate tool schemas, raising [Invalid_argument] for duplicates, empty
    names/descriptions, or non-object input schemas. *)

val all_tool_schemas : Masc_domain.tool_schema list
(** All tool schemas after capability filtering and validation. *)

val all_tool_names : unit -> string list
(** List of all tool names. *)

val is_tool_allowed : string -> bool
(** Check if a tool is allowed on the public catalog surface. *)

val is_raw_tool_name : string -> bool
(** [is_raw_tool_name name] is [true] when [name] appears in
    {!raw_all_tool_schemas} — i.e. the tool universe before any
    capability / visibility filtering.  O(1) via a name-keyed Hashtbl
    built once at module init.  Used on the MCP dispatch hot path
    where the alternative was rebuilding the entire visible schema
    list per call just to membership-test one name. *)

val visible_tool_schemas :
  ?include_hidden:bool ->
  unit -> Masc_domain.tool_schema list
(** Get visible tool schemas. *)
