(** Tool schema registry and visibility helpers. *)

(** Remove duplicate tool schemas by name, keeping the first occurrence. *)
val dedupe_schemas : Types.tool_schema list -> Types.tool_schema list

(** All tool schemas before capability filtering. *)
val raw_all_tool_schemas : Types.tool_schema list

(** Validate tool schemas at module initialization time.
    Logs warnings for duplicates, empty names/descriptions, non-object input_schema. *)
val validate_schemas : Types.tool_schema list -> unit

(** All tool schemas after capability filtering and validation. *)
val all_tool_schemas : Types.tool_schema list

(** List of all tool names. *)
val all_tool_names : unit -> string list

(** Check if a tool is visible. *)
val is_tool_visible : string -> bool

(** Get visible tool schemas. *)
val visible_tool_schemas
  :  ?include_hidden:bool
  -> ?include_deprecated:bool
  -> unit
  -> Types.tool_schema list
