(** Tool schema registry and visibility helpers. *)

val dedupe_schemas : Masc_domain.tool_schema list -> Masc_domain.tool_schema list
(** Remove duplicate tool schemas by name, keeping the first occurrence. *)

val raw_all_tool_schemas : Masc_domain.tool_schema list
(** All tool schemas before capability filtering. *)

val validate_schemas : Masc_domain.tool_schema list -> unit
(** Validate tool schemas at module initialization time.
    Logs warnings for duplicates, empty names/descriptions, non-object input_schema. *)

val all_tool_schemas : Masc_domain.tool_schema list
(** All tool schemas after capability filtering and validation. *)

val all_tool_names : unit -> string list
(** List of all tool names. *)

val is_tool_visible : string -> bool
(** Check if a tool is visible. *)

val visible_tool_schemas :
  ?include_hidden:bool ->
  ?include_deprecated:bool ->
  unit -> Masc_domain.tool_schema list
(** Get visible tool schemas. *)

val surface_tool_schemas :
  ?include_hidden:bool ->
  ?include_deprecated:bool ->
  unit -> Masc_domain.tool_schema list
(** Subset of [visible_tool_schemas] whose [Tool_scope.classify] is
    [Surface]. Initial keeper-internal list is empty, so on PR-N0
    merge this returns the same set as [visible_tool_schemas]. PR-N1+
    populate the keeper-internal list, narrowing this surface. *)

val keeper_internal_tool_schemas : unit -> Masc_domain.tool_schema list
(** Subset whose [Tool_scope.classify] is [Keeper_internal]. Includes
    hidden + deprecated by default since keeper personas may reach
    tools the external MCP surface does not expose. Empty until PR-N1
    populates the keeper-internal list. *)
