(** Tool schema registry and visibility helpers. *)

val dedupe_schemas : Types.tool_schema list -> Types.tool_schema list
(** Remove duplicate tool schemas by name, keeping the first occurrence. *)

val raw_all_tool_schemas : Types.tool_schema list
(** All tool schemas before capability filtering. *)

val validate_schemas : Types.tool_schema list -> unit
(** Validate tool schemas at module initialization time.
    Logs warnings for duplicates, empty names/descriptions, non-object input_schema. *)

val all_tool_schemas : Types.tool_schema list
(** All tool schemas after capability filtering and validation. *)

val all_tool_names : unit -> string list
(** List of all tool names. *)

val is_tool_visible : string -> bool
(** Check if a tool is visible. *)

val visible_tool_schemas :
  ?include_hidden:bool ->
  ?include_deprecated:bool ->
  unit -> Types.tool_schema list
(** Get visible tool schemas. *)
